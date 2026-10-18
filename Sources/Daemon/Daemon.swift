import Foundation
import Core
import GitKit
import Agents
import LocalAI

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
    var config: [String: JSONValue] = [:]
    var sleepAssertion: UInt32 = 0
    var usageCache: (at: Date, value: JSONValue)?
    var chats: [String: ChatSession] = [:]
    var rawConns = Set<Int>()
    private let wakeLock = NSLock()   // one wake per session even when several clients open it at once

    /// `extra` lets integrations (GitHub, Linear) plug in methods without Daemon depending on them.
    public init(root: URL = Paths.root, store: Store? = nil, extra: [String: @Sendable (Daemon, JSONValue) async throws -> JSONValue] = [:]) throws {
        self.root = root
        try Paths.ensure(root)
        self.store = try store ?? Store(path: root.appendingPathComponent("krill.sqlite").path)
        self.socketPath = root.appendingPathComponent("krill.sock").path
        self.extra = extra
        if let d = try? Data(contentsOf: root.appendingPathComponent("config.json")), case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: d) { config = o }
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
        t.setEventHandler { [self] in lock.lock(); let all = Array(live.values); lock.unlock(); all.forEach { $0.tick() }; applyKeepAwake(); hibernateIdle() }
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
                        stream(fd: fd, conn: id, session: req.params?["id"]?.string ?? "", leftover: lb.takeRemainder())
                        break reading
                    }
                    Task { await self.respond(req, conn: id, fd: fd) }
                }
            }
            lock.lock(); conns[id] = nil; let all = Array(live.values); lock.unlock()
            all.forEach { $0.detach(id) }
            close(fd)
        }
    }

    /// Raw attach (`krill attach`, the libghostty terminal): history then live output as plain bytes; whatever the client
    /// writes is the user's typing. Terminal replies (DA, kitty keyboard) flow back the same way, so the agent sees a real terminal.
    private func stream(fd: Int32, conn: Int, session: String, leftover: Data) {
        lock.withLock { _ = rawConns.insert(conn) }   // before waking: its status events must not land in the byte stream
        guard let ls = try? liveSession(session) else {
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

    func liveSession(_ id: String) throws -> LiveSession {
        if let s = lock.withLock({ live[id] }) { return s }
        return try wakeLock.withLock {   // paused sessions wake on first use
            if let s = lock.withLock({ live[id] }) { return s }
            return try wake(id)
        }
    }

    struct Launch {
        var yolo = false, model: String?, effort: String?, resume = false
        var prompt: String?, title: String?
        var profile: String?
        var cols: UInt16 = 120, rows: UInt16 = 32
        var argv: [String]?   // restart: reuse exactly

        init() {}
        init(_ p: JSONValue) {
            yolo = p["mode"]?.string == "yolo" || p["yolo"]?.bool == true
            model = p["model"]?.string; effort = p["effort"]?.string; resume = p["resume"]?.bool == true
            prompt = p["prompt"]?.string; title = p["title"]?.string; profile = p["profile"]?.string
            cols = UInt16(p["cols"]?.int ?? 120); rows = UInt16(p["rows"]?.int ?? 32)
        }
    }

    @discardableResult
    func spawn(cwd: String, manifest: AgentManifest, worktreeId: String?, _ o: Launch = Launch()) throws -> Session {
        var argv = o.argv ?? manifest.argv(yolo: o.yolo, model: o.model, effort: o.effort, resume: o.resume)
        var rec = Session(worktreeId: worktreeId, cwd: cwd, command: argv.joined(separator: " "), agent: manifest.id,
                          title: o.title ?? "", titleManual: o.title != nil, argv: argv)
        if o.argv == nil, let flag = manifest.hooksSettingsFlag {
            let f = root.appendingPathComponent("hooks-\(manifest.id).json")
            try Hooks.writeSettings(to: f)
            argv += [flag, f.path]
            rec.argv = argv
        }
        var env = manifest.env
        if let name = o.profile, let prof = profile(name, agent: manifest.id) { env[prof.key] = prof.dir }
        env["KRILL_SESSION"] = rec.id; env["KRILL_SOCKET"] = socketPath; env["KRILL_HOME"] = root.path
        env["PATH"] = childPath
        let ls = try LiveSession(record: rec, manifest: manifest, argv: [try LoginPath.resolve(argv[0])] + argv.dropFirst(), env: env,
                                 historyDir: root.appendingPathComponent("history"), cols: o.cols, rows: o.rows)
        rec = ls.snapshot
        ls.onOutput = { [weak self] id, data, subs in self?.deliver(id, data, to: subs) }
        ls.onStatus = { [weak self] s in self?.publish(s) }
        let sid = rec.id
        ls.onFirstPrompt = { [weak self] text in Task { await self?.autoTitle(session: sid, prompt: text) } }
        lock.lock(); live[rec.id] = ls; lock.unlock()
        if let p = o.prompt {
            ls.queuePrompt(p)
            if o.title == nil { Task { await autoTitle(session: sid, prompt: p) } }
        }
        try store.save(rec)
        notify("event.session", try .from(rec))
        return rec
    }

    /// Account profiles keep each agent login in its own config dir: switching needs no re-login.
    static let configDirEnv = ["claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"]
    func profile(_ name: String, agent: String) -> (key: String, dir: String)? {
        guard let key = Self.configDirEnv[agent] else { return nil }
        for p in config["profiles"]?.array ?? [] where p["name"]?.string == name && p["agent"]?.string == agent {
            if let d = p["dir"]?.string { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true); return (key, d) }
        }
        return nil
    }

    /// Pause agents that have sat idle (done / waiting) for `hibernateMinutes` with nobody watching.
    func hibernateIdle() {
        let minutes: Double = {
            switch config["hibernateMinutes"] {
            case .int(let i)?: Double(i)
            case .double(let d)?: d
            default: 0
            }
        }()
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
    func wake(_ id: String) throws -> LiveSession {
        guard var rec = try store.session(id), rec.status == .hibernated else { throw RPCError.invalidParams("no live session \(id)") }
        let m = try manifest(rec.agent, command: nil, fallbackArgv: rec.argv)
        var argv = rec.argv
        if !m.resumeArgs.isEmpty, !argv.contains(where: m.resumeArgs.contains) { argv += m.resumeArgs }
        var env = m.env
        env["KRILL_SESSION"] = rec.id; env["KRILL_SOCKET"] = socketPath; env["KRILL_HOME"] = root.path
        env["PATH"] = childPath
        rec.status = .idle
        let ls = try LiveSession(record: rec, manifest: m, argv: [try LoginPath.resolve(argv[0])] + argv.dropFirst(), env: env, historyDir: root.appendingPathComponent("history"), cols: 120, rows: 32)
        ls.onOutput = { [weak self] id, data, subs in self?.deliver(id, data, to: subs) }
        ls.onStatus = { [weak self] s in self?.publish(s) }
        lock.withLock { live[rec.id] = ls }
        publish(ls.snapshot)
        return ls
    }

    func publish(_ s: Session) {
        try? store.save(s)
        if let v = try? JSONValue.from(s) { notify("event.session", v) }
    }

    /// Name a session (and optionally its fresh branch) from the first prompt; a manual title always wins.
    func autoTitle(session id: String, prompt: String) async {
        guard let ls = existing(id), !ls.snapshot.titleManual else { return }
        let naming = await LocalAI.naming(for: prompt)
        let title = naming?.title ?? Fallback.title(prompt)
        let s = ls.update { if !$0.titleManual { $0.title = title } }
        publish(s)
        // A placeholder branch (task-123, wip, new-worktree…) gets a real name from what the agent was asked to do.
        if var w = try? store.worktree(s.worktreeId ?? ""), w.note.range(of: Self.placeholderName, options: .regularExpression) != nil {
            w.note = title; try? store.save(w); notify("event.changed", "worktree")
        }
        if let w = try? store.worktree(s.worktreeId ?? ""), w.branch.range(of: #"^(task|wip|tmp|new|new-worktree|untitled|ws)(-\d+)?$"#, options: .regularExpression) != nil,
           let r = try? store.repo(w.repoId), w.path != r.path {
            let base = naming?.branch ?? Fallback.slug(prompt)
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
