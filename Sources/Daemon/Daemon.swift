import Foundation
import Core
import GitKit
import Agents

/// The long-running process: owns PTYs, state and the JSON-RPC socket.
public final class Daemon: @unchecked Sendable {
    public let store: Store
    let socketPath: String
    let root: URL
    private let lock = NSLock()
    private var live: [String: LiveSession] = [:]
    private var conns: [Int: Int32] = [:]       // connection id -> fd
    private var nextConn = 1
    private var listenFD: Int32 = -1
    private var ticker: DispatchSourceTimer?
    let extra: [String: @Sendable (Daemon, JSONValue) async throws -> JSONValue]

    /// `extra` lets integrations (GitHub, Linear) plug in methods without Daemon depending on them.
    public init(root: URL = Paths.root, store: Store? = nil, extra: [String: @Sendable (Daemon, JSONValue) async throws -> JSONValue] = [:]) throws {
        self.root = root
        try Paths.ensure(root)
        self.store = try store ?? Store(path: root.appendingPathComponent("krill.sqlite").path)
        self.socketPath = root.appendingPathComponent("krill.sock").path
        self.extra = extra
        // Sessions from a previous daemon run lost their PTYs.
        for var s in (try? self.store.sessions()) ?? [] where s.status != .exited {
            s.status = .exited; try? self.store.save(s)
        }
    }

    public func start() throws {
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
        t.setEventHandler { [self] in lock.lock(); let all = Array(live.values); lock.unlock(); all.forEach { $0.tick() } }
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
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                for line in lb.append(Data(buf[0..<n])) {
                    guard let req = try? JSONDecoder().decode(RPCRequest.self, from: line) else { continue }
                    Task { await self.respond(req, conn: id, fd: fd) }
                }
            }
            lock.lock(); conns[id] = nil; let all = Array(live.values); lock.unlock()
            all.forEach { $0.detach(id) }
            close(fd)
        }
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
        lock.lock(); let targets = conns.filter { only == nil || only!.contains($0.key) }.map(\.value); lock.unlock()
        targets.forEach { Unix.writeAll($0, d) }
    }

    // MARK: sessions

    func liveSession(_ id: String) throws -> LiveSession {
        lock.lock(); defer { lock.unlock() }
        guard let s = live[id] else { throw RPCError.invalidParams("no live session \(id)") }
        return s
    }

    @discardableResult
    func spawn(cwd: String, manifest: AgentManifest, worktreeId: String?, cols: UInt16 = 120, rows: UInt16 = 32) throws -> Session {
        var rec = Session(worktreeId: worktreeId, cwd: cwd, command: manifest.commandLine.joined(separator: " "), agent: manifest.id)
        var argv = manifest.commandLine
        if let flag = manifest.hooksSettingsFlag {
            let f = root.appendingPathComponent("hooks-\(manifest.id).json")
            try Hooks.writeSettings(to: f)
            argv += [flag, f.path]
        }
        var env = manifest.env
        env["KRILL_SESSION"] = rec.id; env["KRILL_SOCKET"] = socketPath; env["KRILL_HOME"] = root.path
        let binDir = Bundle.main.executableURL?.deletingLastPathComponent().path ?? ""
        env["PATH"] = [binDir, ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"].filter { !$0.isEmpty }.joined(separator: ":")
        let ls = try LiveSession(record: rec, manifest: manifest, argv: argv, env: env,
                                 historyDir: root.appendingPathComponent("history"), cols: cols, rows: rows)
        rec = ls.snapshot
        ls.onOutput = { [weak self] id, data, subs in
            self?.notify("event.output", .obj(["session": .string(id), "data": .string(data.base64EncodedString())]), to: subs)
        }
        ls.onStatus = { [weak self] s in
            try? self?.store.save(s)
            if let v = try? JSONValue.from(s) { self?.notify("event.session", v) }
        }
        lock.lock(); live[rec.id] = ls; lock.unlock()
        try store.save(rec)
        notify("event.session", try .from(rec))
        return rec
    }

    func manifest(_ id: String?, command: String?) throws -> AgentManifest {
        if let command { return .custom(command) }
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
