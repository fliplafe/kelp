import Foundation
import Core
import GitKit
import Agents
import AgentData

/// The long-running process: owns PTYs, state and the JSON-RPC socket.
public final class Daemon: @unchecked Sendable {   // mutable state (live, appConns…) under lock
    public let store: Store
    let socketPath: String
    let root: URL
    let lock = NSLock()
    var live: [String: LiveSession] = [:]
    private var conns: [Int: Connection] = [:]
    private var nextConn = 1
    private var listenFD: Int32 = -1
    private var instanceLock: Int32 = -1   // flock on kelpd.lock: one daemon per KELP_HOME
    private var ticker: DispatchSourceTimer?
    let extra: [String: @Sendable (Daemon, JSONValue) async throws -> JSONValue]
    let settings: SettingsStore
    var appConns = Set<Int>()               // connections that called ui.publish: they get event.ui
    var uiState: JSONValue = .object([:])   // what the app last published; cleared when no app is connected
    var sleepAssertion: UInt32 = 0
    let keepAwakeLock = NSLock()            // guards sleepAssertion: the ticker and settings changes both apply it
    var usageCache: (at: Date, value: JSONValue)?
    var prCache: [String: (at: Date, value: JSONValue)] = [:]   // "path@branch" → its PR (github.branchPR)
    /// Claude models with the 1M context window (contextWindow); nil until first asked.
    var longContextModels: Set<String>?
    /// Claude Code's usage by day / model / folder, read incrementally (usage.report).
    let usageIndex: UsageIndex
    /// Where Claude Code and Codex keep their conversations, before the account profiles' (tests set it before the first call).
    var agentHomes = (claude: ClaudeHistory.defaultRoot, codex: CodexHistory.defaultRoot)
    var rawConns = Set<Int>()
    var lastMethod = ""
    /// Latest Claude plan usage by kind ("weekly", "session"…), as printed by Claude Code.
    var claudeLimits: [String: (reading: ClaudeLimits.Reading, at: Date)] = [:]
    /// From the agents' own /usage screens, by agent id (UsageProbe).
    var plans: [String: PlanState] = [:]
    func recordLimits(_ r: [ClaudeLimits.Reading]) { lock.withLock { for x in r { claudeLimits[x.kind] = (x, Date()) } } }
    private let wakeLock = NSLock()   // one wake per session even when several clients open it at once

    /// `extra` lets integrations (GitHub, Linear) plug in methods without Daemon depending on them.
    public init(root: URL = Paths.root, store: Store? = nil, extra: [String: @Sendable (Daemon, JSONValue) async throws -> JSONValue] = [:]) throws {
        signal(SIGPIPE, SIG_IGN)   // a client that hangs up mid-write fails that write; it must not end the process (kelpd does this too, tests host a Daemon themselves)
        self.root = root
        try Paths.ensure(root)
        self.store = try store ?? Store(path: root.appendingPathComponent("kelp.sqlite").path)
        self.socketPath = root.appendingPathComponent("kelp.sock").path
        self.extra = extra
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
        instanceLock = lockFD
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
        listenFD = try Unix.listen(socketPath)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .global())
        src.setEventHandler { [self] in
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            if Unix.peerIsUs(fd) { serve(fd) } else { close(fd) }
        }
        src.resume()
        acceptSource = src
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [self] in lock.lock(); let all = Array(live.values); lock.unlock(); all.forEach { $0.tick() }; applyKeepAwake(); hibernateIdle(); pollSettings() }
        t.resume(); ticker = t
    }
    private var acceptSource: DispatchSourceRead?

    public func stop() {
        acceptSource?.cancel(); ticker?.cancel()
        lock.lock(); let all = Array(live.values); let cs = Array(conns.values); lock.unlock()
        all.forEach { $0.pty.kill() }
        cs.forEach { $0.hangUp() }
        close(listenFD); unlink(socketPath)
        if instanceLock >= 0 { close(instanceLock); instanceLock = -1 }
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
        let c = lock.withLock { () -> Connection in
            let c = Connection(id: nextConn, fd: fd); nextConn += 1; conns[c.id] = c; return c
        }
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
                    if req.isNotification, req.method == StateSet.name || req.method == "session.resize" {
                        let p = req.params ?? .null
                        if req.method == StateSet.name { _ = try? StateSet.run(p, self) } else { _ = try? handleSync(req.method, p, conn: c.id) }
                        continue
                    }
                    if req.method == "session.stream" {   // this connection becomes a raw byte pipe (kelp attach)
                        stream(c, session: req.params?["id"]?.string ?? "", size: req.params, leftover: lb.takeRemainder())
                        break reading
                    }
                    Task { await self.respond(req, conn: c) }
                }
            }
            lock.lock(); conns[c.id] = nil; let all = Array(live.values)
            if appConns.remove(c.id) != nil, appConns.isEmpty { uiState = .object([:]) }
            lock.unlock()
            all.forEach { $0.detach(c.id) }
            c.close()
        }
    }

    /// Raw attach (`kelp attach`, the libghostty terminal): history then live output as plain bytes; whatever the client
    /// writes is the user's typing. Terminal replies (DA, kitty keyboard) flow back the same way, so the agent sees a real terminal.
    /// `size`: the attaching terminal's cols / rows, so a paused agent wakes at the size it's shown at.
    /// An ended session shows what it last printed (from its log), then the attach ends.
    private func stream(_ c: Connection, session: String, size: JSONValue?, leftover: Data) {
        lock.withLock { _ = rawConns.insert(c.id) }   // before waking: its status events must not land in the byte stream
        defer { lock.withLock { _ = rawConns.remove(c.id) } }
        if existing(session) == nil, (try? store.session(session))?.status == .exited {
            c.send(TerminalReplies.withoutQueries((try? liveSessionOrLog(session, bytes: LiveSession.ringLimit)) ?? Data())); return
        }
        let (cols, rows) = Launch.size(size)
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
        let (raw, json): ([Connection], Set<Int>) = lock.withLock {
            (subs.filter { rawConns.contains($0) }.compactMap { conns[$0] }, subs.subtracting(rawConns))
        }
        raw.forEach { $0.send(data) }
        if !json.isEmpty { notify("event.output", .obj(["session": .string(id), "data": .string(data.base64EncodedString())]), to: json) }
    }

    private func respond(_ req: Request, conn c: Connection) async {
        let reply: Reply
        let id = req.id ?? .null
        do { reply = Reply(id: id, result: try await handle(req.method, req.params ?? .null, conn: c.id), error: nil) }
        catch let e as RPCError { reply = Reply(id: id, result: nil, error: e) }
        catch { reply = Reply(id: id, result: nil, error: .internalError("\(error)")) }
        if !req.isNotification, let d = try? Wire.line(reply) { c.send(d) }
    }

    func notify(_ method: String, _ params: JSONValue, to only: Set<Int>? = nil) {
        guard let d = try? Wire.line(RPCRequest(id: nil, method: method, params: params)) else { return }
        lock.lock(); let targets = conns.filter { !rawConns.contains($0.key) && only?.contains($0.key) != false }.map(\.value); lock.unlock()
        targets.forEach { $0.send(d) }
    }

    // MARK: sessions

    /// A running session, without waking a paused one.
    func existing(_ id: String) -> LiveSession? { lock.withLock { live[id] } }

    func liveSession(_ id: String, cols: UInt16 = 120, rows: UInt16 = 32) throws -> LiveSession {
        if let s = lock.withLock({ live[id] }) { return s }
        return try wakeLock.withLock {   // paused sessions wake on first use
            if let s = lock.withLock({ live[id] }) { return s }
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

        init() {}
        init(_ p: JSONValue) {
            model = p["model"]?.string; effort = p["effort"]?.string; resume = p["resume"]?.bool == true
            prompt = p["prompt"]?.string; title = p["title"]?.string; profile = p["profile"]?.string; draft = p["draft"]?.bool == true
            openURLs = p["openURLs"]?.bool == true
            (cols, rows) = Self.size(p)
        }

        /// A terminal size from `{cols, rows}`: anything out of range is clamped, nothing (or 0) is 120 × 32.
        static func size(_ p: JSONValue?) -> (cols: UInt16, rows: UInt16) {
            let c = UInt16(clamping: p?["cols"]?.int ?? 0), r = UInt16(clamping: p?["rows"]?.int ?? 0)
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
        if local, o.argv == nil, let flag = manifest.sessionIdFlag, !manifest.resumes(argv) { argv += [flag, rec.id.lowercased()] }
        rec.argv = argv
        var env = manifest.resolvedEnv
        if let name = o.profile, let prof = profile(name, agent: manifest.id) { env[prof.key] = prof.dir }
        env["KELP_SESSION"] = rec.id; env["KELP_SOCKET"] = socketPath; env["KELP_HOME"] = root.path
        env["PATH"] = childPath
        let ls = try LiveSession(record: rec, manifest: manifest, argv: try launchArgv(argv, cwd: cwd, manifest: manifest), env: env,
                                 historyDir: root.appendingPathComponent("history"), cols: o.cols, rows: o.rows)
        rec = ls.snapshot
        let sid = rec.id
        wire(ls)
        ls.onFirstPrompt = { [weak self] text in self?.autoTitle(session: sid, prompt: text) }
        if !["shell", "custom"].contains(manifest.id) {
            ls.onTopic = { [weak self] t in
                guard let self else { return }
                DispatchQueue.global(qos: .utility).async { self.retitle(session: sid, topic: t) }
            }
        }
        if o.openURLs, let wid = worktreeId {   // e.g. Jupyter Lab: its URL opens in the worktree's browser
            ls.onLocalURL = { [weak self] url in self?.notify("event.devserver", .obj(["worktree": .string(wid), "url": .string(url), "session": .string(sid)])) }
        }
        lock.lock(); live[rec.id] = ls; lock.unlock()
        defer { ls.start() }   // after the record is saved (its first status must not be overwritten), and in any case
        if let p = o.prompt {
            ls.queuePrompt(p, draft: o.draft)
            if o.title == nil { DispatchQueue.global(qos: .utility).async { [weak self] in self?.autoTitle(session: sid, prompt: p) } }
        }
        try store.save(rec)
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
    private func wire(_ ls: LiveSession) {
        ls.onOutput = { [weak self] id, data, subs in self?.deliver(id, data, to: subs) }
        ls.onStatus = { [weak self, weak ls] s in
            guard let self, let ls, !ls.isDiscarded else { return }
            publish(s); ls.noteTurn(s.status)
            if s.status == .exited { lock.withLock { if live[s.id] === ls { live[s.id] = nil } } }
        }
        if ls.snapshot.agent == "claude" { ls.onLimits = { [weak self] r in self?.recordLimits(r) } }
    }

    /// Deletes a session for good: it stops, its record and log go, and its exit can't save it again.
    func discard(_ s: Session) {
        let ls = lock.withLock { live.removeValue(forKey: s.id) }
        ls?.discard()
        try? store.delete(s)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("history/\(s.id).log"))
    }

    /// One sentence naming the skills that are turned on (their folders exist).
    static func kelpContext(_ dir: URL) -> String? {
        let on = ["kelp-extensions", "kelp-settings"].filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        guard !on.isEmpty else { return nil }
        return "This Claude Code session runs inside Kelp, a macOS IDE; the user sees Kelp's window, not Claude Code's UI. Any request to add "
            + "or change a panel, tab, list, command, setting or theme means Kelp: follow the \(on.joined(separator: " / ")) skill. "
            + "Never create Claude Code mods, plugins, hooks or MCP servers for such requests — Kelp doesn't load them."
    }

    static func hasPlugins(_ dir: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).contains(where: \.hasDirectoryPath)
    }

    /// Account profiles keep each agent login in its own config dir: switching needs no re-login.
    static let configDirEnv = ["claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"]
    func profile(_ name: String, agent: String) -> (key: String, dir: String)? {
        guard let key = Self.configDirEnv[agent] else { return nil }
        for p in settings["accounts.profiles"]?.array ?? [] where p["name"]?.string == name && p["agent"]?.string == agent {
            if let d = p["dir"]?.string { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true); return (key, d) }
        }
        return nil
    }

    /// Pause agents that have sat idle (done / waiting) for `hibernateMinutes` with nobody watching.
    func hibernateIdle() {
        let minutes = settings.number("sessions.hibernateMinutes") ?? 0
        guard minutes > 0 else { return }
        let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
        let candidates = lock.withLock { Array(live.values) }.filter { ls in
            let s = ls.snapshot
            guard [.done, .waiting, .idle].contains(s.status), !ls.isAttached, ls.idleSeconds > minutes * 60 else { return false }
            return manifests.first { $0.id == s.agent }?.resumeArgs.isEmpty == false
        }
        for ls in candidates {
            let s = ls.markHibernated()
            ls.pty.kill()
            lock.withLock { live[s.id] = nil }
            publish(s)
        }
    }

    /// Bring a paused session back under the same id (layout and links stay), resuming its conversation.
    /// KELP_DEBUG_WAKE=1: log which request woke a paused session (a paused agent should wake only when opened).
    static let debugWake = ProcessInfo.processInfo.environment["KELP_DEBUG_WAKE"] != nil

    func wake(_ id: String, cols: UInt16 = 120, rows: UInt16 = 32) throws -> LiveSession {
        if Self.debugWake { FileHandle.standardError.write(Data("WAKE \(id) by \(lock.withLock { lastMethod })\n".utf8)) }
        guard var rec = try store.session(id), rec.status == .hibernated else { throw RPCError.invalidParams("no live session \(id)") }
        let m = try manifest(rec.agent, command: nil, fallbackArgv: rec.argv)
        let argv = resumeArgv(rec, m)
        rec.argv = argv   // the conversation it found is this session's from now on
        var env = m.resolvedEnv
        env["KELP_SESSION"] = rec.id; env["KELP_SOCKET"] = socketPath; env["KELP_HOME"] = root.path
        env["PATH"] = childPath
        rec.status = .idle
        let ls = try LiveSession(record: rec, manifest: m, argv: try launchArgv(argv, cwd: rec.cwd, manifest: m), env: env,
                                 historyDir: root.appendingPathComponent("history"), cols: cols, rows: rows)
        wire(ls)
        lock.withLock { live[rec.id] = ls }
        publish(ls.snapshot)
        ls.start()
        return ls
    }

    /// argv that brings back this session's own conversation. A remote one's conversations are on its host: the agent's
    /// own "latest in this folder" finds it there.
    func resumeArgv(_ rec: Session, _ m: AgentManifest) -> [String] {
        guard rec.agent == "claude", RemoteHost.of(rec.cwd) == nil, let flag = m.resumeIdFlag, let pin = m.sessionIdFlag else { return m.resuming(rec.argv) }
        if rec.argv.contains(flag) { return rec.argv }
        let conversations = ClaudeHistory.sessions(cwd: rec.cwd)
        if let i = rec.argv.firstIndex(of: pin), i + 1 < rec.argv.count {
            // Pinned but nothing typed yet: no conversation to resume, start it under the same id.
            return conversations.contains { $0.id.lowercased() == rec.argv[i + 1].lowercased() } ? m.resuming(rec.argv) : rec.argv
        }
        // From before ids were pinned (or restarted with "latest in this folder", which hands it another agent's
        // conversation): the first conversation that started here between this session and the next one, unless another
        // session has it; none → start fresh. Limit: misses prompts typed out of order across sessions.
        let base = rec.argv.filter { !m.resumeArgs.contains($0) }
        let all = (try? store.sessions()) ?? []
        let claimed = Set(all.filter { $0.id != rec.id }.flatMap { s in
            s.argv.indices.dropLast().filter { [pin, flag].contains(s.argv[$0]) }.map { s.argv[$0 + 1].lowercased() }
        })
        let next = all.filter { $0.agent == "claude" && $0.cwd == rec.cwd && $0.createdAt > rec.createdAt }.map(\.createdAt).min() ?? .distantFuture
        let own = conversations
            .filter { $0.started >= rec.createdAt.addingTimeInterval(-2) && $0.started < next && !claimed.contains($0.id.lowercased()) }
            .min { $0.started < $1.started }
        return own.map { base + [flag, $0.id] } ?? base
    }

    func publish(_ s: Session) {
        try? store.save(s)
        if let v = try? JSONValue.from(s) { notify("event.session", v) }
        if s.status == .done || s.status == .waiting, let a = s.agent { planUsed(a) }
    }

    /// Name a session (and optionally its fresh branch) from the first prompt; a manual title always wins.
    /// Runs git: call it off the cooperative pool (it's called on GCD).
    func autoTitle(session id: String, prompt: String) {
        guard let ls = existing(id), !ls.snapshot.titleManual, ls.topic == nil else { return }   // the agent's own topic is better
        let title = Naming.title(prompt)
        let s = ls.update { if !$0.titleManual { $0.title = title } }
        publish(s)
        // A placeholder branch (task-123, wip, new-worktree…) gets a real name from what the agent was asked to do.
        if var w = try? store.worktree(s.worktreeId ?? ""), w.note.range(of: Self.placeholderName, options: .regularExpression) != nil {
            w.note = title; try? store.save(w); notify("event.changed", "worktree")
        }
        if let w = try? store.worktree(s.worktreeId ?? ""), w.branch.range(of: #"^(task|wip|tmp|new|new-worktree|untitled|ws)(-\d+)?$"#, options: .regularExpression) != nil,
           let r = try? store.repo(w.repoId), w.path != r.path {
            let base = Naming.slug(prompt)
            var b = base, n = 2
            while Git.branchExists(r.path, b) { b = "\(base)-\(n)"; n += 1 }
            if !base.isEmpty, (try? Git.renameBranch(w.path, from: w.branch, to: b)) != nil {
                var nw = w; nw.branch = b; if nw.note.isEmpty { nw.note = title }
                try? store.save(nw); notify("event.changed", "worktree")
            }
        }
    }

    /// The agent's own short topic (Claude Code's terminal title) names the session instead of its prompt, and its
    /// workspace while that still has the name the session gave it (or a placeholder). A title set by hand stays.
    func retitle(session id: String, topic: String) {
        guard let ls = existing(id), !ls.snapshot.titleManual, ls.snapshot.title != topic else { return }
        let old = ls.snapshot.title
        let s = ls.update { if !$0.titleManual { $0.title = topic } }
        publish(s)
        if var w = try? store.worktree(s.worktreeId ?? ""),
           (!old.isEmpty && w.note == old) || w.note.range(of: Self.placeholderName, options: .regularExpression) != nil {
            w.note = topic; try? store.save(w); notify("event.changed", "worktree")
        }
    }

    func manifest(_ id: String?, command: String?, fallbackArgv: [String]? = nil) throws -> AgentManifest {
        if let command { return .custom(command) }
        if id == "custom", let a = fallbackArgv { return .init(id: "custom", name: "Custom", command: a.first ?? "/bin/zsh", args: Array(a.dropFirst())) }
        let id = id ?? "shell"
        // A plain shell has no meaningful "done": keep the heuristic quiet.
        if id == "shell" { return .init(id: "shell", name: "Shell", command: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", args: ["-l"], quietSeconds: 1e9) }
        guard let m = AgentManifest.load(dir: root.appendingPathComponent("agents")).first(where: { $0.id == id }) else {
            throw RPCError.invalidParams("unknown agent \(id)")
        }
        return m
    }

    func cwd(forWorktree id: String) throws -> Worktree {
        guard let w = try store.worktree(id) else { throw RPCError.invalidParams("no worktree \(id)") }
        return w
    }
}
