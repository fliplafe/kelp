import Foundation
import os
import Core
import GitKit
import Agents
import AgentData

/// The long-running process: owns PTYs, state and the JSON-RPC socket.
/// Running sessions and who is connected each keep their own lock; the order they're taken in is in `Clients`.
public final class Daemon: Sendable {
    public let store: Store
    let socketPath: String
    let root: URL
    let live = SessionTable()
    let clients = Clients()
    /// What start() opens and stop() closes: the socket, the flock on kelpd.lock (one daemon per KELP_HOME), the sources.
    private struct Running: @unchecked Sendable {   // the sources are only set up and cancelled, under `running`'s lock
        var listenFD: Int32 = -1, instanceLock: Int32 = -1
        var accept: DispatchSourceRead?, ticker: DispatchSourceTimer?
    }
    private let running = OSAllocatedUnfairLock(initialState: Running())
    let settings: SettingsStore
    // Each under a lock of its own (not `lock`, which guards the sessions and connections): nothing else depends on them.
    /// The Mac kept awake while agents work (applyKeepAwake): the ticker and a settings change both apply it.
    let sleepAssertion = OSAllocatedUnfairLock<(id: UInt32, type: String?)>(initialState: (0, nil))
    let usageCache = OSAllocatedUnfairLock<(at: Date, value: JSONValue)?>(initialState: nil)
    let prCache = OSAllocatedUnfairLock<[String: (at: Date, value: GitHub.PullRequest?)]>(initialState: [:])   // "path@branch" → its PR (github.branchPR)
    /// Claude models with the 1M context window (contextWindow); nil until first asked.
    let longContextModels = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)
    /// Claude Code's usage by day / model / folder, read incrementally (usage.report).
    let usageIndex: UsageIndex
    /// Where Claude Code and Codex keep their conversations, before the account profiles' (tests set it before the first call).
    let agentHomes = OSAllocatedUnfairLock(initialState: (claude: ClaudeHistory.defaultRoot, codex: CodexHistory.defaultRoot))
    /// Latest Claude plan usage by kind ("weekly", "session"…), as printed by Claude Code.
    let claudeLimits = OSAllocatedUnfairLock<[String: (reading: ClaudeLimits.Reading, at: Date)]>(initialState: [:])
    /// From the agents' own /usage screens, by agent id (UsageProbe).
    let plans = OSAllocatedUnfairLock<[String: PlanState]>(initialState: [:])
    func recordLimits(_ r: [ClaudeLimits.Reading]) { claudeLimits.withLock { for x in r { $0[x.kind] = (x, Date()) } } }
    let pausingIdle = OSAllocatedUnfairLock(initialState: false)   // one round of idle pausing at a time, off the ticker
    let wakeLocks = WakeLocks()   // one wake per session even when several clients open it at once; pausing holds it too
    let trustLock = NSLock()   // trusted-configs.json: read-modify-write under it
    let settingsEvents = DispatchQueue(label: "kelp.settings-events")   // event.settings in order: the last one is the settings now
    /// Reading the projects' desks and adding the missing first one is one step: two lists at once added two "Workspace 1".
    let deskLock = NSRecursiveLock()

    public init(root: URL = Paths.root, store: Store? = nil) throws {
        signal(SIGPIPE, SIG_IGN)   // a client that hangs up mid-write fails that write; it must not end the process (kelpd does this too, tests host a Daemon themselves)
        self.root = root
        try Paths.ensure(root)
        self.store = try store ?? Store(path: root.appendingPathComponent("kelp.sqlite").path)
        self.socketPath = root.appendingPathComponent("kelp.sock").path
        self.settings = SettingsStore(root: root)
        self.usageIndex = UsageIndex(cache: root.appendingPathComponent("usage-index-2.json"))   // new number: a parser change reads everything again
        // Shared SSH connections for remote projects (short: a Unix socket path has to fit in 104 bytes).
        let ssh = root.appendingPathComponent("ssh"); try? Paths.ensure(ssh); RemoteHost.controlDir = ssh.path
        RemoteHost.trust(root.appendingPathComponent("remote"))   // the only place a .kelp-remote counts
    }

    /// `kelp` (hooks, the ctty trampoline) first, then the user's login-shell PATH.
    var childPath: String {
        [Bundle.main.executableURL?.deletingLastPathComponent().path ?? "", LoginPath.value].filter { !$0.isEmpty }.joined(separator: ":")
    }

    /// When this binary was built; the app compares it with the kelpd it ships to spot a stale daemon after an update.
    static let binaryMTime: Double = {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return (try? FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }()

    public func start() throws {
        // One daemon per KELP_HOME: a second one (launchd's KeepAlive, a CLI that couldn't connect) would take the socket
        // over and mark the first one's running agents paused.
        let lockFD = open(root.appendingPathComponent("kelpd.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            throw RPCError.internalError("another kelpd is already running for \(root.path)")
        }
        running.withLock { $0.instanceLock = lockFD }
        // Sessions from a previous daemon run lost their PTYs; resumable agents come back as paused, the rest as exited.
        for var s in (try? store.sessions()) ?? [] where s.status != .exited {
            let m = AgentManifest.load(dir: root.appendingPathComponent("agents")).first { $0.id == s.agent }
            s.status = (m?.resumeArgs.isEmpty == false) ? .hibernated : .exited
            s.progress = nil   // what ran there isn't getting any further
            try? store.save(s)
        }
        _ = Self.binaryMTime   // read now: after an update the file on disk is already the new one
        DispatchQueue.global().async { _ = LoginPath.value }   // warm up so the first agent doesn't wait for the shell
        // The usage index reads gigabytes the first time: do it in the background now, not when Usage is opened.
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 30) { [self] in
            let since = Calendar.current.date(byAdding: .day, value: -89, to: Calendar.current.startOfDay(for: Date())) ?? Date()
            _ = usageIndex.rows(roots: agentRoots().claude.filter { FileManager.default.fileExists(atPath: $0.path) }, since: since)
        }
        let listenFD: Int32
        do { listenFD = try Unix.listen(socketPath) } catch {
            running.withLock { if $0.instanceLock >= 0 { close($0.instanceLock); $0.instanceLock = -1 } }   // not ours to keep
            throw error
        }
        // Accept and the ticker have queues of their own (serial queues get a thread even when every pooled one is held
        // by a slow git or ssh in `offload`), so new connections and status keep going whatever is stuck.
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: DispatchQueue(label: "kelp.accept"))
        src.setCancelHandler { close(listenFD) }   // after any accept still running, not under it
        src.setEventHandler { [self, weak src] in
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                // Out of fds, the socket stays readable and this would run again at once, spinning: wait for some to free.
                if errno == EMFILE || errno == ENFILE, let src { src.suspend(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { src.resume() } }
                return
            }
            if Unix.peerIsUs(fd) { Unix.noSigPipe(fd); serve(fd) } else { close(fd) }
        }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "kelp.ticker"))
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [self] in live.all.forEach { $0.tick() }; applyKeepAwake(); hibernateIdle(); pollSettings() }
        running.withLock { $0.listenFD = listenFD; $0.accept = src; $0.ticker = t }
        src.resume(); t.resume()
    }

    public func stop() {
        let r = running.withLock { r in defer { r = Running() }; return r }
        r.accept?.cancel(); r.ticker?.cancel()   // the accept source's cancel closes the socket
        if r.accept == nil, r.listenFD >= 0 { close(r.listenFD) }
        // Every program ends with the daemon, whole trees (a job in a process group of its own, an agent that ignores the
        // hangup), each recorded as pausing records it: a resumable agent comes back paused, not as a second copy.
        let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
        let pids = live.all.flatMap { ls in live.remove(ls.snapshot.id).map { pause($0, manifests) } ?? [] }
        Self.waitGone(pids)
        clients.everyone().forEach { $0.hangUp() }
        unlink(socketPath)
        if r.instanceLock >= 0 { close(r.instanceLock) }
    }

    // MARK: connections

    /// A request as it comes: JSON-RPC lets the id be a string too, and the reply carries it back as it came.
    struct Request: Decodable {
        let id: JSONValue?
        let method: String
        let params: JSONValue?
        var isNotification: Bool { id == nil || id == .null }
    }
    struct Reply: Encodable {
        var jsonrpc = "2.0"
        let id: JSONValue
        let result: JSONValue?
        let error: RPCError?
    }

    private func serve(_ fd: Int32) {
        let c = clients.add(fd: fd)
        Thread.detachNewThread { [self] in
            var lb = LineBuffer()
            var buf = [UInt8](repeating: 0, count: 65536)
            reading: while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                for line in lb.append(Data(buf[0..<n])) {
                    guard let req = try? JSONDecoder().decode(Request.self, from: line) else {
                        // Not a request: say so to whoever sent an id, rather than leave it waiting.
                        if let id = (try? JSONDecoder().decode(JSONValue.self, from: line))?["id"], id != .null, let d = try? Wire.line(
                            Reply(id: id, result: nil, error: RPCError(code: -32600, message: "invalid request"))) { c.send(d) }
                        continue
                    }
                    if req.isNotification, req.method == "session.write" {   // keystrokes: in order, on this thread
                        if let sid = req.params?["id"]?.string, let b = req.params?["base64"]?.string, let d = Data(base64Encoded: b) { existing(sid)?.userInput(d) }
                        continue
                    }
                    // Quick, and only right in the order they were sent: a saved layout or a terminal size that finished second
                    // must not win over the newer one. Applied here, one after another, like keystrokes.
                    if req.isNotification, req.method == StateSet.name || req.method == "session.resize" || req.method == "ui.publish" {
                        let p = req.params ?? .null
                        switch req.method {
                        case StateSet.name: _ = try? StateSet.run(p, self, conn: c.id)
                        case "ui.publish": _ = try? handleUI(req.method, p, conn: c.id)
                        default: _ = try? handleSync(req.method, p, conn: c.id)
                        }
                        continue
                    }
                    if req.method == "session.stream" {   // this connection becomes a raw byte pipe (kelp attach)
                        stream(c, session: req.params?["id"]?.string ?? "", size: req.params, leftover: lb.takeRemainder())
                        break reading
                    }
                    Task { await self.respond(req, conn: c) }
                }
            }
            clients.remove(c.id)   // first: an attach finishing now sees it gone (Clients.ifConnected)
            live.all.forEach { $0.detach(c.id) }
            c.close()
        }
    }

    /// Raw attach (`kelp attach`, the libghostty terminal): history then live output as plain bytes; whatever the client
    /// writes is the user's typing. Terminal replies (DA, kitty keyboard) flow back the same way, so the agent sees a real terminal.
    /// `size`: the attaching terminal's cols / rows, so a paused agent wakes at the size it's shown at.
    /// An ended session shows what it last printed (from its log), then the attach ends.
    private func stream(_ c: Connection, session: String, size: JSONValue?, leftover: Data) {
        clients.setRaw(c.id, true)   // before waking: its status events must not land in the byte stream
        defer { clients.setRaw(c.id, false) }
        if existing(session) == nil, (try? store.session(session))?.status == .exited {
            c.send(TerminalReplies.withoutQueries((try? liveSessionOrLog(session, bytes: LiveSession.ringLimit)) ?? Data())); return
        }
        let (cols, rows) = Launch.size(cols: size?["cols"]?.int, rows: size?["rows"]?.int)
        guard let ls = try? liveSession(session, cols: cols, rows: rows) else { c.send(Data("kelp: no such session\r\n".utf8)); return }
        ls.attach(c.id) { c.send($0) }   // queued under the session's lock: no live output gets ahead of it
        if !leftover.isEmpty { ls.userInput(leftover) }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c.fd, &buf, buf.count)
            if n <= 0 { break }
            ls.userInput(Data(buf[0..<n]))
        }
        ls.detach(c.id)
    }

    /// Output to attached connections: raw ones get bytes, the rest a JSON event.
    func deliver(_ id: String, _ data: Data, to subs: Set<Int>) {
        let (raw, json) = clients.split(subs)
        raw.forEach { $0.send(data) }
        if !json.isEmpty { notify("event.output", .obj(["session": .string(id), "data": .string(data.base64EncodedString())]), to: json) }
    }

    private func respond(_ req: Request, conn c: Connection) async {
        let reply: Reply
        let id = req.id ?? .null
        // Attach: the reply with the history is queued in the same step that subscribes, so no live output can reach this
        // connection ahead of it (the screen would show the newest bytes before the history they follow).
        if req.method == "session.attach", !req.isNotification, let sid = req.params?["id"]?.string,
           existing(sid) != nil || (try? store.session(sid))?.status == .hibernated,
           let ls = try? await offload({ [self] in try liveSession(sid) }) {
            // Only while it's still connected: one that closed while the session woke isn't subscribed (it would count as
            // watching for good, and the session would never pause).
            clients.ifConnected(c.id) {
                _ = ls.attach(c.id) { history in
                    if let d = try? Wire.line(Reply(id: id, result: .obj(["history": .string(history.base64EncodedString())]), error: nil)) { c.send(d) }
                }
            }
            return
        }
        do { reply = Reply(id: id, result: try await handle(req.method, req.params ?? .null, conn: c.id), error: nil) }
        catch let e as RPCError { reply = Reply(id: id, result: nil, error: e) }
        catch { reply = Reply(id: id, result: nil, error: .internalError("\(error)")) }
        if !req.isNotification, let d = try? Wire.line(reply) { c.send(d) }
    }

    func notify(_ method: String, _ params: JSONValue, to only: Set<Int>? = nil) {
        guard let d = try? Wire.line(RPCRequest(id: nil, method: method, params: params)) else { return }
        clients.targets(only).forEach { $0.send(d) }
    }

    // MARK: sessions

    /// A running session, without waking a paused one.
    func existing(_ id: String) -> LiveSession? { live[id] }

    func liveSession(_ id: String, cols: UInt16 = 120, rows: UInt16 = 32) throws -> LiveSession {
        if let s = live[id] { return s }
        return try wakeLocks.withLock(id) {   // paused sessions wake on first use
            if let s = live[id] { return s }
            return try wake(id, cols: cols, rows: rows)
        }
    }

    struct Launch {
        var model: String?, effort: String?, resume = false
        var prompt: String?, title: String?
        var draft = false   // type the prompt, don't send it
        var profile: String?
        var openURLs = false   // the first local URL it prints opens in the workspace's browser (event.devserver)
        var cols: UInt16 = 120, rows: UInt16 = 32
        var argv: [String]?   // restart: reuse exactly

        /// A terminal size: anything out of range is clamped, nothing (or 0) is 120 × 32.
        static func size(cols: Int?, rows: Int?) -> (cols: UInt16, rows: UInt16) {
            let c = UInt16(clamping: cols ?? 0), r = UInt16(clamping: rows ?? 0)
            return (c > 0 ? c : 120, r > 0 ? r : 32)
        }
    }

    @discardableResult
    func spawn(cwd: String, manifest: AgentManifest, worktreeId: String?, _ o: Launch = Launch()) throws -> Session {
        var argv = o.argv ?? manifest.argv(model: o.model, effort: o.effort, resume: o.resume)
        var rec = Session(worktreeId: worktreeId, cwd: cwd, command: argv.joined(separator: " "), agent: manifest.id,
                          title: o.title ?? "", titleManual: o.title != nil, argv: argv)
        // A remote project's sessions run on its host (see `launchArgv`). Kelp's hooks and skills are files on this Mac,
        // so they stay out: status comes from what the screen shows.
        let local = RemoteHost.of(cwd) == nil
        if local, o.argv == nil, let flag = manifest.hooksSettingsFlag {
            let f = root.appendingPathComponent("hooks-\(manifest.id).json")
            try Hooks.writeSettings(to: f)
            argv += [flag, f.path]
        }
        // Kelp's skills (written by the app, only the ones turned on), for this session only: nothing goes into ~/.claude.
        if local, o.argv == nil, let flag = manifest.pluginDirFlag, Self.hasPlugins(Paths.agentSkills) {
            argv += [flag, Paths.agentSkills.path]
            // Without a word of context, "add a panel" reads as a request for the agent's own UI.
            if let ctx = manifest.contextFlag, let text = Self.kelpContext(Paths.agentSkills) { argv += [ctx, text] }
        }
        // Its own id, unless it resumes one (a restart's argv carries none: see session.restart).
        if local, let flag = manifest.sessionIdFlag, !argv.contains(flag), !manifest.resumes(argv) { argv += [flag, rec.id.lowercased()] }
        rec.argv = argv
        rec.profile = o.profile
        let env = launchEnv(manifest, rec)
        let ls = try LiveSession(record: rec, manifest: trustAnswered(manifest, cwd: cwd, worktreeId: worktreeId, env: env),
                                 argv: try launchArgv(argv, cwd: cwd, manifest: manifest), env: env,
                                 historyDir: root.appendingPathComponent("history"), cols: o.cols, rows: o.rows)
        rec = ls.snapshot
        let sid = rec.id
        wire(ls)
        if o.openURLs, let wid = worktreeId {   // e.g. Jupyter Lab: its URL opens in the worktree's browser
            ls.onLocalURL = { [weak self] url in self?.notify("event.devserver", .obj(["worktree": .string(wid), "url": .string(url), "session": .string(sid)])) }
        }
        // The record first: a program nobody has a record of could be neither seen nor stopped.
        do { try store.save(rec) } catch { ls.discard(); ls.start(); throw error }   // start: so its exit is reaped, no zombie
        live.add(ls)
        if let p = o.prompt {
            ls.queuePrompt(p, draft: o.draft)
            if o.title == nil { DispatchQueue.global(qos: .utility).async { [weak self] in self?.autoTitle(session: sid, prompt: p) } }
        }
        ls.start()   // after the record is saved: its first status must not be overwritten
        notify("event.session", try .from(rec))
        return rec
    }

    /// What runs: `argv` itself, or for a remote project ssh running it in the project's folder on the host. Records
    /// keep the plain argv, so a restart or a wake wraps it once (older records kept the ssh line: that runs as it is).
    func launchArgv(_ argv: [String], cwd: String, manifest: AgentManifest) throws -> [String] {
        var run = argv
        if let remote = RemoteHost.of(cwd), argv.first != RemoteHost.ssh {
            // A command line (`.custom`: zsh -lc "…") goes to sh there: the host may have no zsh.
            let onHost = manifest.id == "custom" && argv.count == 3 && argv[1] == "-lc" ? ["sh", "-c", argv[2]] : argv
            run = [RemoteHost.ssh] + remote.sshArgs(tty: true) + [remote.command(manifest.id == "shell" ? nil : onHost)]
        }
        guard let exe = run.first else { throw RPCError.invalidParams("empty command") }
        return [try LoginPath.resolve(exe)] + run.dropFirst()
    }

    /// Output, status and limits go out from the first byte (`start()` comes after). An ended session leaves `live`:
    /// its fd and pid belong to nobody now, and its log still shows what it printed.
    func wire(_ ls: LiveSession) {
        ls.onOutput = { [weak self] id, data, subs in self?.deliver(id, data, to: subs) }
        ls.onStatus = { [weak self, weak ls] s in
            guard let self, let ls, !ls.isDiscarded else { return }
            // The record as it is now, not the snapshot from when this change was queued: a title set meanwhile stays.
            // The turn bookkeeping gets each change, in order.
            publish(ls.snapshot); ls.noteTurn(s.status)
            if s.status == .exited { _ = live.remove(ls) }
        }
        if ls.snapshot.agent == "claude" { ls.onLimits = { [weak self] r in self?.recordLimits(r) } }
        // Naming follows the session however it started (created, or woken from a pause).
        let sid = ls.snapshot.id
        ls.onFirstPrompt = { [weak self] text in self?.autoTitle(session: sid, prompt: text) }
        if !["shell", "custom"].contains(ls.snapshot.agent ?? "custom") {
            ls.onTopic = { [weak self] t in
                guard let self else { return }
                DispatchQueue.global(qos: .utility).async { self.retitle(session: sid, topic: t) }
            }
        }
    }

    /// Deletes a session for good: it stops, its record and log go, and its exit can't save it again.
    /// Under its wake lock, as a wake is: a paused session being opened at this moment can't come back after its record and log
    /// are gone (it would restart an agent for a deleted project and save the record again).
    func discard(_ s: Session) {
        wakeLocks.withLock(s.id) {
            let ls = live.remove(s.id)
            if let ls { Self.waitGone(ls.discard()) }   // gone before its project or folder goes (SIGKILL after 2 s)
            try? store.delete(s)
            try? FileManager.default.removeItem(at: root.appendingPathComponent("history/\(s.id).log"))
        }
    }
}
