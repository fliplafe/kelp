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
    let usageCache = OSAllocatedUnfairLock<(at: Date, value: UsageGet.Result)?>(initialState: nil)
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
    let lanes = SessionLanes()   // input for a paused session wakes it off the reader thread, in order
    let offloads = Slots(Daemon.offloadLimit)   // what `offload` runs at once
    let lsp = LSPHost()   // language servers: one per project and server command, shared by every client
    let watches = Watches()   // what clients watch (watch.start), read while anyone does and pushed when it changed
    let wakeLocks = WakeLocks()   // one wake per session even when several clients open it at once; pausing holds it too
    let trustLock = NSLock()   // trusted-configs.json: read-modify-write under it
    let settingsEvents = DispatchQueue(label: "kelp.settings-events")   // event.settings in order: the last one is the settings now
    /// Reading the projects' desks and adding the missing first one is one step: two syncs at once added two "Workspace 1".
    let deskLock = NSLock()   // held across git calls (a blocking run), so not the unfair lock
    let heads = OSAllocatedUnfairLock<[String: HeadWatch]>(initialState: [:])   // by project: its .git, for desks to follow the branch

    public init(root: URL = Paths.root, store: Store? = nil) throws {
        signal(SIGPIPE, SIG_IGN)   // a client that hangs up mid-write fails that write; it must not end the process (kelpd does this too, tests host a Daemon themselves)
        self.root = root
        try Paths.ensure(root)
        self.store = try store ?? Store(path: root.appendingPathComponent("kelp.sqlite").path)
        self.socketPath = root.appendingPathComponent("kelp.sock").path
        self.settings = SettingsStore(root: root)
        self.usageIndex = UsageIndex(cache: root.appendingPathComponent("usage-index-2.json"))   // new number: a parser change reads everything again
        // Shared SSH connections for remote projects (short: a Unix socket path has to fit in 104 bytes).
        let ssh = root.appendingPathComponent("ssh")
        do { try Paths.ensure(ssh) } catch { Log.start.error("no folder for ssh connections: \(error)") }   // remote projects fail
        RemoteHost.controlDir = ssh.path
        RemoteHost.trust(root.appendingPathComponent("remote"))   // the only place a .kelp-remote counts
        self.store.changed.withLock {
            $0 = { [weak self] c in
                self?.recordChanged(c)   // records go to the clients as they change
                switch c {   // and a project added, moved or removed is followed (watchHeads) from then on
                case .repo, .repoRemoved: self?.watchHeads()
                default: break
                }
            }
        }
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
        // Sessions from a previous daemon run lost their PTYs; resumable ones come back as paused, the rest as exited.
        let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
        do {
            for var s in try store.sessions() where s.status != .exited {
                s.status = Self.resumable(s, manifests) ? .hibernated : .exited
                s.progress = nil   // what ran there isn't getting any further
                try store.save(s)
            }
        } catch { Log.store.error("couldn't mark the last run's sessions paused or ended: \(error)") }
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
        Self.headQueue.async { [weak self] in if self?.running.withLock({ $0.accept != nil }) == true { self?.followHeads() } }   // not once stopped
        try? FileManager.default.removeItem(at: Paths.daemonError(in: root))   // an earlier failure is over
        Log.start.info("kelpd \(getpid()) serves \(self.socketPath, privacy: .public)")
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
        lsp.stopAll()
        watches.stopAll()
        let h = heads.withLock { h in defer { h = [:] }; return h }
        _ = h   // the streams stop here, out of the lock
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
                    // Quick, and only right in the order they were sent (keystrokes, a setting dragged, two sends; a saved
                    // layout or a terminal size that finished second must not win over the newer one): applied here, one
                    // after another, calls and notifications alike (`Answered.inOrder`); a call's reply goes out in that order.
                    if let t = Self.methods[req.method] as? any Handled.Type, t.inOrder {
                        let id = req.id ?? .null
                        do {
                            let r = try answerNow(t, req.params ?? .null, conn: c.id)
                            if !req.isNotification { c.send(Self.replyLine(id: id, result: r)) }
                        } catch {
                            if !req.isNotification, let d = Self.errorLine(id: id, error) { c.send(d) }
                        }
                        continue
                    }
                    // The one method by name: it ends JSON-RPC on this connection, which becomes a raw byte pipe (kelp attach).
                    if req.method == "session.stream" {
                        stream(c, session: req.params?["id"]?.string ?? "", size: req.params, leftover: lb.takeRemainder())
                        break reading
                    }
                    Task { await self.respond(req, conn: c) }
                }
            }
            clients.remove(c.id)   // first: an attach finishing now sees it gone (Clients.ifConnected)
            watches.drop(c.id)
            live.all.forEach { $0.detach(c.id) }
            lsp.closeAll(conn: c.id)   // its files: a server left with none stops a while later
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
        if !json.isEmpty { notify(OutputEvent(session: id, data: data), to: json) }
    }

    private func respond(_ req: Request, conn c: Connection) async {
        let id = req.id ?? .null
        // Attach: the reply with the history is queued in the same step that subscribes, so no live output can reach this
        // connection ahead of it (the screen would show the newest bytes before the history they follow).
        // The one method that answers itself (SessionAttach's own handler serves an ended session): its reply has to be
        // queued inside the session's lock, which `Handled` can't express.
        if req.method == SessionAttach.name, !req.isNotification, let sid = (try? SessionAttach.decoded(req.params ?? .null))?.id,
           existing(sid) != nil || (try? store.session(sid))?.status == .hibernated,
           let ls = try? await offload({ [self] in try liveSession(sid) }) {
            // Only while it's still connected: one that closed while the session woke isn't subscribed (it would count as
            // watching for good, and the session would never pause).
            clients.ifConnected(c.id) {
                _ = ls.attach(c.id) { history in
                    if let r = try? JSONEncoder().encode(SessionAttach.Result(history: history.base64EncodedString())) { c.send(Self.replyLine(id: id, result: r)) }
                }
            }
            return
        }
        do {
            let r = try await answer(req.method, req.params ?? .null, conn: c.id)
            if !req.isNotification { c.send(Self.replyLine(id: id, result: r)) }
        } catch {
            if let e = error as? RPCError { Log.rpc.debug("\(req.method, privacy: .public) failed: \(e.message)") }
            else { Log.rpc.error("\(req.method, privacy: .public) failed: \(error)") }
            if !req.isNotification, let d = Self.errorLine(id: id, error) { c.send(d) }
        }
    }

    /// A reply line around a result already encoded: the result isn't decoded and encoded again on its way out.
    static func replyLine(id: JSONValue, result: Data) -> Data {
        var d = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        d.append((try? JSONEncoder().encode(id)) ?? Data("null".utf8))
        d.append(Data(#","result":"#.utf8)); d.append(result); d.append(Data("}\n".utf8))
        return d
    }
    static func errorLine(id: JSONValue, _ error: Error) -> Data? {
        try? Wire.line(Reply(id: id, result: nil, error: (error as? RPCError) ?? .internalError("\(error)")))
    }

    func notify(_ e: some RPCEvent, to only: Set<Int>? = nil) {
        guard let d = try? Wire.line(RPCNotification(e)) else { return }
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
        var tmux: String?   // restart: the host's tmux session the old one's agent still runs in

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
        // A remote agent runs in a tmux session of its own on the host: a dropped connection or a daemon restart leaves it working.
        if !local, !["shell", "custom"].contains(manifest.id) { rec.tmux = o.tmux ?? Tmux.own() }
        let env = launchEnv(manifest, rec)
        let ls = try LiveSession(record: rec, manifest: liveManifest(manifest, cwd: cwd, worktreeId: worktreeId, env: env),
                                 argv: try launchArgv(argv, cwd: cwd, manifest: manifest, tmux: rec.tmux), env: env,
                                 historyDir: root.appendingPathComponent("history"), cols: o.cols, rows: o.rows,
                                 callbacks: callbacks(for: rec, devServerIn: o.openURLs ? worktreeId : nil))   // e.g. Jupyter Lab's URL
        if o.tmux != nil { ls.attachedToRunning() }
        rec = ls.snapshot
        let sid = rec.id
        // The record first: a program nobody has a record of could be neither seen nor stopped.
        do { try store.save(rec) } catch { ls.discard(); ls.start(); throw error }   // start: so its exit is reaped, no zombie
        live.add(ls)
        if let p = o.prompt {
            ls.queuePrompt(p, draft: o.draft)
            if o.title == nil { DispatchQueue.global(qos: .utility).async { [weak self] in self?.autoTitle(session: sid, prompt: p) } }
        }
        ls.start()   // after the record is saved: its first status must not be overwritten
        notify(rec)
        return rec
    }

    /// What runs: `argv` itself, or for a remote project ssh running it in the project's folder on the host. Records
    /// keep the plain argv, so a restart or a wake wraps it once (older records kept the ssh line: that runs as it is).
    func launchArgv(_ argv: [String], cwd: String, manifest: AgentManifest, tmux: String? = nil) throws -> [String] {
        var run = argv
        if let remote = RemoteHost.of(cwd), argv.first != RemoteHost.ssh {
            // A command line (`.custom`: zsh -lc "…") goes to sh there: the host may have no zsh.
            let onHost = manifest.id == "custom" && argv.count == 3 && argv[1] == "-lc" ? ["sh", "-c", argv[2]] : argv
            let loginShell = manifest.id == "shell" && Tmux.session(argv) == nil
            let command = tmux.map { remote.command(onHost, inTmux: $0) } ?? remote.command(loginShell ? nil : onHost)
            run = [RemoteHost.ssh] + remote.sshArgs(tty: true) + [command]
        }
        guard let exe = run.first else { throw RPCError.invalidParams("empty command") }
        return [try LoginPath.resolve(exe)] + run.dropFirst()
    }

    /// What a session tells the daemon, from its first byte on. An ended session leaves `live`: its fd and pid belong to
    /// nobody now, and its log still shows what it printed. `devServerIn`: the first local URL it prints opens in that
    /// workspace's browser.
    func callbacks(for rec: Session, devServerIn worktree: String? = nil) -> LiveSession.Callbacks {
        let sid = rec.id
        var c = LiveSession.Callbacks()
        c.output = { [weak self] id, data, subs in self?.deliver(id, data, to: subs) }
        c.status = { [weak self] ls, s in
            guard let self, !ls.isDiscarded else { return }
            // The record as it is now, not the snapshot from when this change was queued: a title set meanwhile stays.
            // The turn bookkeeping gets each change, in order.
            publish(ls.snapshot); ls.noteTurn(s.status)
            if s.status == .exited { _ = live.remove(ls) }
        }
        if rec.agent == "claude" { c.limits = { [weak self] r in self?.recordLimits(r) } }
        // Naming follows the session however it started (created, or woken from a pause).
        c.firstPrompt = { [weak self] text in self?.autoTitle(session: sid, prompt: text) }
        if !["shell", "custom"].contains(rec.agent ?? "custom") {
            c.topic = { [weak self] t in
                guard let self else { return }
                DispatchQueue.global(qos: .utility).async { self.retitle(session: sid, topic: t) }
            }
        }
        if let worktree { c.localURL = { [weak self] url in self?.notify(DevServerEvent(worktree: worktree, url: url, session: sid)) } }
        return c
    }

    /// Deletes a session for good: it stops, its record and log go, and its exit can't save it again.
    /// Under its wake lock, as a wake is: a paused session being opened at this moment can't come back after its record and log
    /// are gone (it would restart an agent for a deleted project and save the record again). A terminal's own tmux session
    /// ends with it unless `keepTmux` (a restart, whose new session attaches to it).
    func discard(_ s: Session, keepTmux: Bool = false) {
        if !keepTmux { endOwnTmux(s) }
        wakeLocks.withLock(s.id) {
            let ls = live.remove(s.id)
            if let ls { Self.waitGone(ls.discard()) }   // gone before its project or folder goes (SIGKILL after 2 s)
            do { try store.delete(s) } catch { Log.store.error("couldn't delete session \(s.id, privacy: .public): \(error)") }
            try? FileManager.default.removeItem(at: root.appendingPathComponent("history/\(s.id).log"))   // none when it never ran
        }
    }
}
