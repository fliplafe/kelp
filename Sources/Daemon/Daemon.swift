import Foundation
import Core
import GitKit
import Agents
import AgentData

/// The long-running process: owns PTYs, state and the JSON-RPC socket.
public final class Daemon: @unchecked Sendable {
    public let store: Store
    let socketPath: String
    let root: URL
    let lock = NSLock()
    var live: [String: LiveSession] = [:]
    private var conns: [Int: Int32] = [:]       // connection id -> fd
    private var nextConn = 1
    private var listenFD: Int32 = -1
    private var ticker: DispatchSourceTimer?
    let extra: [String: @Sendable (Daemon, JSONValue) async throws -> JSONValue]
    let settings: SettingsStore
    var appConns = Set<Int>()               // connections that called ui.publish: they get event.ui
    var uiState: JSONValue = .object([:])   // what the app last published; cleared when no app is connected
    var sleepAssertion: UInt32 = 0
    var usageCache: (at: Date, value: JSONValue)?
    var prCache: [String: (at: Date, value: JSONValue)] = [:]   // "path@branch" → its PR (github.branchPR)
    /// Claude Code's usage by day / model / folder, read incrementally (usage.report).
    let usageIndex: UsageIndex
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
        self.root = root
        try Paths.ensure(root)
        self.store = try store ?? Store(path: root.appendingPathComponent("krill.sqlite").path)
        self.socketPath = root.appendingPathComponent("krill.sock").path
        self.extra = extra
        self.settings = SettingsStore(root: root)
        self.usageIndex = UsageIndex(cache: root.appendingPathComponent("usage-index-2.json"))   // new number: a parser change reads everything again
        // Shared SSH connections for remote projects (short: a Unix socket path has to fit in 104 bytes).
        let ssh = root.appendingPathComponent("ssh"); try? Paths.ensure(ssh); RemoteHost.controlDir = ssh.path
        // Sessions from a previous daemon run lost their PTYs; resumable agents come back as paused, the rest as exited.
        for var s in (try? self.store.sessions()) ?? [] where s.status != .exited {
            let m = AgentManifest.load(dir: root.appendingPathComponent("agents")).first { $0.id == s.agent }
            s.status = (m?.resumeArgs.isEmpty == false) ? .hibernated : .exited
            try? self.store.save(s)
        }
    }

    /// `krill` (hooks, the ctty trampoline) first, then the user's login-shell PATH.
    var childPath: String {
        [Bundle.main.executableURL?.deletingLastPathComponent().path ?? "", LoginPath.value].filter { !$0.isEmpty }.joined(separator: ":")
    }

    /// When this binary was built; the app compares it with the krilld it ships to spot a stale daemon after an update.
    static let binaryMTime: Double = {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return (try? FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }()

    public func start() throws {
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
            if fd >= 0 { serve(fd) }
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
        cs.forEach { shutdown($0, SHUT_RDWR) }
        close(listenFD); unlink(socketPath)
    }

    // MARK: connections

    private func serve(_ fd: Int32) {
        lock.lock(); let id = nextConn; nextConn += 1; conns[id] = fd; lock.unlock()
        Thread.detachNewThread { [self] in
            var lb = LineBuffer()
            var buf = [UInt8](repeating: 0, count: 65536)
            reading: while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                for line in lb.append(Data(buf[0..<n])) {
                    guard let req = try? JSONDecoder().decode(RPCRequest.self, from: line) else { continue }
                    if req.id == nil, req.method == "session.write" {   // keystrokes: in order, on this thread
                        if let sid = req.params?["id"]?.string, let b = req.params?["base64"]?.string, let d = Data(base64Encoded: b) { existing(sid)?.userInput(d) }
                        continue
                    }
                    if req.method == "session.stream" {   // this connection becomes a raw byte pipe (krill attach)
                        stream(fd: fd, conn: id, session: req.params?["id"]?.string ?? "", size: req.params, leftover: lb.takeRemainder())
                        break reading
                    }
                    Task { await self.respond(req, conn: id, fd: fd) }
                }
            }
            lock.lock(); conns[id] = nil; let all = Array(live.values)
            if appConns.remove(id) != nil, appConns.isEmpty { uiState = .object([:]) }
            lock.unlock()
            all.forEach { $0.detach(id) }
            close(fd)
        }
    }

    /// Raw attach (`krill attach`, the libghostty terminal): history then live output as plain bytes; whatever the client
    /// writes is the user's typing. Terminal replies (DA, kitty keyboard) flow back the same way, so the agent sees a real terminal.
    /// `size`: the attaching terminal's cols / rows, so a paused agent wakes at the size it's shown at.
    private func stream(fd: Int32, conn: Int, session: String, size: JSONValue?, leftover: Data) {
        lock.withLock { _ = rawConns.insert(conn) }   // before waking: its status events must not land in the byte stream
        let cols = UInt16(clamping: size?["cols"]?.int ?? 120), rows = UInt16(clamping: size?["rows"]?.int ?? 32)
        guard let ls = try? liveSession(session, cols: cols > 0 ? cols : 120, rows: rows > 0 ? rows : 32) else {
            _ = Unix.writeAll(fd, Data("krill: no such session\r\n".utf8)); lock.withLock { _ = rawConns.remove(conn) }; return
        }
        let history = ls.attach(conn)
        Unix.writeAll(fd, history)
        if !leftover.isEmpty { ls.userInput(leftover) }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            ls.userInput(Data(buf[0..<n]))
        }
        ls.detach(conn)
        lock.withLock { _ = rawConns.remove(conn) }
    }

    /// Output to attached connections: raw ones get bytes, the rest a JSON event.
    func deliver(_ id: String, _ data: Data, to subs: Set<Int>) {
        let (raw, json): ([Int32], Set<Int>) = lock.withLock {
            (subs.filter { rawConns.contains($0) }.compactMap { conns[$0] }, subs.subtracting(rawConns))
        }
        raw.forEach { Unix.writeAll($0, data) }
        if !json.isEmpty { notify("event.output", .obj(["session": .string(id), "data": .string(data.base64EncodedString())]), to: json) }
    }

    private func respond(_ req: RPCRequest, conn: Int, fd: Int32) async {
        let resp: RPCResponse
        do { resp = RPCResponse(id: req.id, result: try await handle(req.method, req.params ?? .null, conn: conn)) }
        catch let e as RPCError { resp = RPCResponse(id: req.id, error: e) }
        catch { resp = RPCResponse(id: req.id, error: .internalError("\(error)")) }
        if req.id != nil, let d = try? Wire.line(resp) { Unix.writeAll(fd, d) }
    }

    func notify(_ method: String, _ params: JSONValue, to only: Set<Int>? = nil) {
        guard let d = try? Wire.line(RPCRequest(id: nil, method: method, params: params)) else { return }
        lock.lock(); let targets = conns.filter { !rawConns.contains($0.key) && only?.contains($0.key) != false }.map(\.value); lock.unlock()
        targets.forEach { Unix.writeAll($0, d) }
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
        var yolo = false, model: String?, effort: String?, resume = false
        var prompt: String?, title: String?
        var draft = false   // type the prompt, don't send it
        var profile: String?
        var cols: UInt16 = 120, rows: UInt16 = 32
        var argv: [String]?   // restart: reuse exactly

        init() {}
        init(_ p: JSONValue) {
            yolo = p["mode"]?.string == "yolo" || p["yolo"]?.bool == true
            model = p["model"]?.string; effort = p["effort"]?.string; resume = p["resume"]?.bool == true
            prompt = p["prompt"]?.string; title = p["title"]?.string; profile = p["profile"]?.string; draft = p["draft"]?.bool == true
            cols = UInt16(p["cols"]?.int ?? 120); rows = UInt16(p["rows"]?.int ?? 32)
        }
    }

    @discardableResult
    func spawn(cwd: String, manifest: AgentManifest, worktreeId: String?, _ o: Launch = Launch()) throws -> Session {
        var argv = o.argv ?? manifest.argv(yolo: o.yolo, model: o.model, effort: o.effort, resume: o.resume)
        var rec = Session(worktreeId: worktreeId, cwd: cwd, command: argv.joined(separator: " "), agent: manifest.id,
                          title: o.title ?? "", titleManual: o.title != nil, argv: argv)
        // A remote project's sessions run on its host. Krill's hooks and skills are files on this Mac, so they stay
        // out: status comes from what the screen shows.
        if let remote = RemoteHost.of(cwd) {
            argv = [RemoteHost.ssh] + remote.sshArgs(tty: true) + [remote.command(manifest.id == "shell" ? nil : argv)]
            rec.argv = argv
        } else if o.argv == nil, let flag = manifest.hooksSettingsFlag {
            let f = root.appendingPathComponent("hooks-\(manifest.id).json")
            try Hooks.writeSettings(to: f)
            argv += [flag, f.path]
            rec.argv = argv
        }
        // Krill's skills (written by the app, only the ones turned on), for this session only: nothing goes into ~/.claude.
        if o.argv == nil, RemoteHost.of(cwd) == nil, let flag = manifest.pluginDirFlag, Self.hasPlugins(Paths.agentSkills) {
            argv += [flag, Paths.agentSkills.path]
            // Without a word of context, "add a panel" reads as a request for the agent's own UI.
            if let ctx = manifest.contextFlag, let text = Self.krillContext(Paths.agentSkills) { argv += [ctx, text] }
            rec.argv = argv
        }
        if o.argv == nil, RemoteHost.of(cwd) == nil, let flag = manifest.sessionIdFlag, !manifest.resumes(argv) {
            argv += [flag, rec.id.lowercased()]
            rec.argv = argv
        }
        var env = manifest.resolvedEnv
        if let name = o.profile, let prof = profile(name, agent: manifest.id) { env[prof.key] = prof.dir }
        env["KRILL_SESSION"] = rec.id; env["KRILL_SOCKET"] = socketPath; env["KRILL_HOME"] = root.path
        env["PATH"] = childPath
        let ls = try LiveSession(record: rec, manifest: manifest, argv: [try LoginPath.resolve(argv[0])] + argv.dropFirst(), env: env,
                                 historyDir: root.appendingPathComponent("history"), cols: o.cols, rows: o.rows)
        rec = ls.snapshot
        ls.onOutput = { [weak self] id, data, subs in self?.deliver(id, data, to: subs) }
        ls.onStatus = { [weak self, weak ls] s in self?.publish(s); ls?.noteTurn(s.status) }
        if ls.snapshot.agent == "claude" { ls.onLimits = { [weak self] r in self?.recordLimits(r) } }
        let sid = rec.id
        ls.onFirstPrompt = { [weak self] text in Task { await self?.autoTitle(session: sid, prompt: text) } }
        lock.lock(); live[rec.id] = ls; lock.unlock()
        if let p = o.prompt {
            ls.queuePrompt(p, draft: o.draft)
            if o.title == nil { Task { await autoTitle(session: sid, prompt: p) } }
        }
        try store.save(rec)
        notify("event.session", try .from(rec))
        return rec
    }

    /// One sentence naming the skills that are turned on (their folders exist).
    static func krillContext(_ dir: URL) -> String? {
        let on = ["krill-extensions", "krill-settings"].filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        guard !on.isEmpty else { return nil }
        return "This Claude Code session runs inside Krill, a macOS IDE; the user sees Krill's window, not Claude Code's UI. Any request to add "
            + "or change a panel, tab, list, command, setting or theme means Krill: follow the \(on.joined(separator: " / ")) skill. "
            + "Never create Claude Code mods, plugins, hooks or MCP servers for such requests — Krill doesn't load them."
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
    /// KRILL_DEBUG_WAKE=1: log which request woke a paused session (a paused agent should wake only when opened).
    static let debugWake = ProcessInfo.processInfo.environment["KRILL_DEBUG_WAKE"] != nil

    func wake(_ id: String, cols: UInt16 = 120, rows: UInt16 = 32) throws -> LiveSession {
        if Self.debugWake { FileHandle.standardError.write(Data("WAKE \(id) by \(lock.withLock { lastMethod })\n".utf8)) }
        guard var rec = try store.session(id), rec.status == .hibernated else { throw RPCError.invalidParams("no live session \(id)") }
        let m = try manifest(rec.agent, command: nil, fallbackArgv: rec.argv)
        let argv = resumeArgv(rec, m)
        rec.argv = argv   // the conversation it found is this session's from now on
        var env = m.resolvedEnv
        env["KRILL_SESSION"] = rec.id; env["KRILL_SOCKET"] = socketPath; env["KRILL_HOME"] = root.path
        env["PATH"] = childPath
        rec.status = .idle
        let ls = try LiveSession(record: rec, manifest: m, argv: [try LoginPath.resolve(argv[0])] + argv.dropFirst(), env: env, historyDir: root.appendingPathComponent("history"), cols: cols, rows: rows)
        ls.onOutput = { [weak self] id, data, subs in self?.deliver(id, data, to: subs) }
        ls.onStatus = { [weak self, weak ls] s in self?.publish(s); ls?.noteTurn(s.status) }
        if ls.snapshot.agent == "claude" { ls.onLimits = { [weak self] r in self?.recordLimits(r) } }
        lock.withLock { live[rec.id] = ls }
        publish(ls.snapshot)
        return ls
    }

    /// argv that brings back this session's own conversation.
    func resumeArgv(_ rec: Session, _ m: AgentManifest) -> [String] {
        guard rec.agent == "claude", let flag = m.resumeIdFlag, let pin = m.sessionIdFlag else { return m.resuming(rec.argv) }
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
    }

    /// Name a session (and optionally its fresh branch) from the first prompt; a manual title always wins.
    func autoTitle(session id: String, prompt: String) async {
        guard let ls = existing(id), !ls.snapshot.titleManual else { return }
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
