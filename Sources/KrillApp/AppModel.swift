import AppKit
import Core
import Agents

/// UI-side mirror of daemon state. The app talks to the daemon only through JSON-RPC.
@MainActor
final class AppModel {
    static let shared = AppModel()

    var client: RPCClient?
    var repos: [Repo] = []
    var worktrees: [Worktree] = []
    var sessions: [Session] = []
    var agents: [AgentManifest] = AgentManifest.load()

    var onChange: [() -> Void] = []
    var onSessionStatus: [(Session, Session?) -> Void] = []     // new, old
    private var outputHandlers: [String: (Data) -> Void] = [:]

    func connect() async {
        for attempt in 0..<2 {
            if let c = try? RPCClient() { client = c; break }
            if attempt == 0 { launchDaemon() }
            for _ in 0..<30 { try? await Task.sleep(for: .milliseconds(100)); if let c = try? RPCClient() { client = c; break } }
            if client != nil { break }
        }
        guard let c = client else { return }
        c.onNotification = { [weak self] m, p in Task { @MainActor in self?.handle(m, p) } }
        c.onClose = { [weak self] in Task { @MainActor in self?.client = nil; self?.reconnectSoon() } }
        await refresh()
    }

    private func reconnectSoon() {
        Task { try? await Task.sleep(for: .seconds(1)); await connect() }
    }

    private func launchDaemon() {
        let dir = Bundle.main.executableURL!.deletingLastPathComponent()
        let p = Process(); p.executableURL = dir.appendingPathComponent("krilld")
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func refresh() async {
        guard let c = client else { return }
        repos = (try? await c.call("repo.list", as: [Repo].self)) ?? repos
        worktrees = (try? await c.call("worktree.list", as: [Worktree].self)) ?? worktrees
        sessions = (try? await c.call("session.list", as: [Session].self)) ?? sessions
        onChange.forEach { $0() }
    }

    private func handle(_ method: String, _ p: JSONValue) {
        switch method {
        case "event.output":
            if let id = p["session"]?.string, let b = p["data"]?.string, let d = Data(base64Encoded: b) { outputHandlers[id]?(d) }
        case "event.session":
            guard let s = try? p.decode(Session.self) else { return }
            let old = sessions.first { $0.id == s.id }
            if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
            if old?.status != s.status { DashboardController.events.append(AgentEvent(date: Date(), session: s, status: s.status)); if DashboardController.events.count > 500 { DashboardController.events.removeFirst(100) } }
            onSessionStatus.forEach { $0(s, old) }
            onChange.forEach { $0() }
        case "event.changed":
            Task { await refresh() }
        default: break
        }
    }

    // MARK: calls

    @discardableResult
    func call(_ method: String, _ params: JSONValue? = nil) async -> JSONValue? {
        do { return try await client?.call(method, params) }
        catch {
            let a = NSAlert(); a.messageText = "krill: \(method) failed"; a.informativeText = "\((error as? RPCError)?.message ?? "\(error)")"
            a.runModal(); return nil
        }
    }

    /// Replays history, then streams live output into `sink`.
    func attach(session id: String, sink: @escaping (Data) -> Void) async {
        outputHandlers[id] = sink
        if let r = try? await client?.call("session.attach", .obj(["id": .string(id)])),
           let h = r["history"]?.string, let d = Data(base64Encoded: h) { sink(d) }
    }
    func detach(session id: String) { outputHandlers[id] = nil; Task { _ = try? await client?.call("session.detach", .obj(["id": .string(id)])) } }
    func write(session id: String, _ d: Data) { Task { _ = try? await client?.call("session.write", .obj(["id": .string(id), "base64": .string(d.base64EncodedString())])) } }
    func resize(session id: String, cols: Int, rows: Int) { Task { _ = try? await client?.call("session.resize", .obj(["id": .string(id), "cols": .int(cols), "rows": .int(rows)])) } }

    func worktree(_ id: String?) -> Worktree? { worktrees.first { $0.id == id } }
    func repo(_ id: String?) -> Repo? { repos.first { $0.id == id } }
    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }
}
