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
    var onChatLine: ((String, String) -> Void)?
    /// Claude Code subagents per session (title, active), polled while the parent works.
    var subagents: [String: [(title: String, active: Bool)]] = [:]
    private var subagentTimer: Timer?
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
        if await checkDaemonVersion(c) { return }
        c.onNotification = { [weak self] m, p in Task { @MainActor in self?.handle(m, p) } }
        c.onClose = { [weak self] in Task { @MainActor in self?.client = nil; self?.reconnectSoon() } }
        await refresh()
    }

    private var restartAttempted = false
    private var bundledDaemon: URL { Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("krilld") }

    /// After an app update the running daemon may be older. Restart it right away when no agent is running;
    /// otherwise ask, because restarting ends running sessions. Returns true when a restart is in progress.
    private func checkDaemonVersion(_ c: RPCClient) async -> Bool {
        guard let mine = (try? FileManager.default.attributesOfItem(atPath: bundledDaemon.path)[.modificationDate] as? Date)?.timeIntervalSince1970 else { return false }
        var info: JSONValue = .null
        do { info = try await c.call("daemon.info") } catch let e as RPCError where e.code == RPCError.methodNotFound.code {
            info = .obj(["liveSessions": .int(((try? await c.call("session.list").array) ?? []).filter { $0["status"]?.string != "exited" }.count)])   // predates daemon.info
        } catch { return false }
        let theirs: Double = { if case .double(let d)? = info["mtime"] { return d }; return Double(info["mtime"]?.int ?? 0) }()
        let samePath = info["path"]?.string == bundledDaemon.resolvingSymlinksInPath().path
        guard !(samePath && abs(theirs - mine) < 1), !restartAttempted else { return false }
        restartAttempted = true   // one try per launch: a daemon too old to shut down is left running rather than looping
        if (info["liveSessions"]?.int ?? 0) > 0 {
            let a = NSAlert(); a.messageText = "Krill was updated"
            a.informativeText = "The background service is still the previous version. Restart it to finish the update — running agent sessions will end. You can also do it later from the Krill menu."
            a.addButton(withTitle: "Restart Service"); a.addButton(withTitle: "Later")
            guard a.runModal() == .alertFirstButtonReturn else { return false }
        }
        _ = try? await c.call("daemon.shutdown")
        c.close(); client = nil
        try? await Task.sleep(for: .milliseconds(600))
        await connect()
        return true
    }

    func restartDaemon() async {
        _ = try? await client?.call("daemon.shutdown"); client?.close(); client = nil
        try? await Task.sleep(for: .milliseconds(600)); await connect()
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

    func startSubagentPolling() {
        subagentTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated { Task { await AppModel.shared.pollSubagents() } }
        }
    }
    private func pollSubagents() async {
        var changed = false
        for s in sessions where s.agent == "claude" && (s.status == .working || subagents[s.id] != nil) {
            let list = ((try? await client?.call("session.subagents", .obj(["id": .string(s.id)])).array) ?? [])
                .map { (title: $0["title"]?.string ?? "Subagent", active: $0["active"]?.bool ?? false) }
            let old = subagents[s.id] ?? []
            if old.map(\.title) != list.map(\.title) || old.map(\.active) != list.map(\.active) { subagents[s.id] = list.isEmpty ? nil : list; changed = true }
        }
        if changed { onChange.forEach { $0() } }
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
        case "event.chat":
            if let id = p["id"]?.string, let line = p["line"]?.string { onChatLine?(id, line) }
        case "event.devserver":
            if let w = p["worktree"]?.string, let u = p["url"]?.string {
                NotificationCenter.default.post(name: .krillDevServerURL, object: nil, userInfo: ["worktree": w, "url": u])
            }
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
    func write(session id: String, _ d: Data) { client?.notify("session.write", .obj(["id": .string(id), "base64": .string(d.base64EncodedString())])) }
    func resize(session id: String, cols: Int, rows: Int) { Task { _ = try? await client?.call("session.resize", .obj(["id": .string(id), "cols": .int(cols), "rows": .int(rows)])) } }

    func worktree(_ id: String?) -> Worktree? { worktrees.first { $0.id == id } }
    func repo(_ id: String?) -> Repo? { repos.first { $0.id == id } }
    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }
}
