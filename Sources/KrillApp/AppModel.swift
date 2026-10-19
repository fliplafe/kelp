import AppKit
import Core
import Agents

/// UI-side mirror of daemon state (observable: SwiftUI views update only what changed).
/// The app talks to the daemon only through JSON-RPC.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    @ObservationIgnored var client: RPCClient?
    var connected = false
    var repos: [Repo] = []
    var worktrees: [Worktree] = []
    var sessions: [Session] = []
    /// How full each agent's conversation is (0…1), read when a turn ends (Claude Code transcripts).
    var contextShare: [String: Double] = [:]
    @ObservationIgnored var agents: [AgentManifest] = AgentManifest.load()

    @ObservationIgnored var onChange: [() -> Void] = []
    @ObservationIgnored var onSessionStatus: [(Session, Session?) -> Void] = []     // new, old
    @ObservationIgnored private var outputHandlers: [String: (Data) -> Void] = [:]

    /// Workspaces of a project: the main one (the repo itself) first, then newest first.
    /// In the order they were opened: Workspace 1, 2, 3… (older ones on their own branch included).
    func workspaces(of r: Repo) -> [Worktree] {
        worktrees.filter { $0.repoId == r.id && !$0.archived }.sorted { $0.createdAt < $1.createdAt }
    }

    func upsert(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
    }

    /// Tells the daemon what's on screen, so agents can ask (`krill ui state`, MCP).
    func publishUIState() {
        guard let c = client else { return }
        let w = worktree(Workbench.shared.workspaceId)
        let reg = ExtensionRegistry.shared
        let state: JSONValue = .obj([
            "workspace": w.map { .obj(["id": .string($0.id), "name": .string($0.displayName), "path": .string($0.path), "branch": .string($0.branch)]) } ?? .null,
            "focusedSession": Workbench.shared.focusedSession.map { .string($0) } ?? .null,
            "focusedFile": Workbench.shared.focusedFile.map { .string($0) } ?? .null,
            "editor": Workbench.editor?.stateForAgents ?? .null,
            "extensions": .array(reg.extensions.map { e in
                .obj(["id": .string(e.id), "name": .string(e.name), "enabled": .bool(e.enabled), "builtin": .bool(e.builtin),
                      "path": e.path.map { .string($0.path) } ?? .null, "error": e.error.map { .string($0) } ?? .null])
            }),
            "commands": .array(reg.all.commands.map { .obj(["id": .string($0.id), "title": .string($0.title)]) }),
            "panels": .array(reg.all.panels.map { .obj(["id": .string($0.id), "title": .string($0.title)]) })
        ])
        c.notify("ui.publish", .obj(["state": state]))
    }

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
        c.onClose = { [weak self] in Task { @MainActor in self?.client = nil; self?.connected = false; self?.reconnectSoon() } }
        connected = true
        await SettingsStore.shared.load()
        await refresh()
        publishUIState()
    }

    private var restartAttempted = false
    /// Where krilld and krill sit next to the app binary.
    private var binDir: URL { (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent() }
    private var bundledDaemon: URL { binDir.appendingPathComponent("krilld") }

    /// After an app update the running daemon may be older. Restart it right away when no agent is running;
    /// otherwise ask, because restarting ends running sessions. Returns true when a restart is in progress.
    private func checkDaemonVersion(_ c: RPCClient) async -> Bool {
        guard let mine = (try? FileManager.default.attributesOfItem(atPath: bundledDaemon.path)[.modificationDate] as? Date)?.timeIntervalSince1970 else { return false }
        var info: JSONValue = .null
        do { info = try await c.call("daemon.info") } catch let e as RPCError where e.code == RPCError.methodNotFound.code {
            info = .obj(["liveSessions": .int(((try? await c.call("session.list").array) ?? []).filter { $0["status"]?.string != "exited" }.count)])   // predates daemon.info
        } catch { return false }
        // Older daemons don't report binaryMTime (and their "mtime" was read from disk, i.e. already the new file): restart them.
        let theirs: Double = { if case .double(let d)? = info["binaryMTime"] { return d }; return Double(info["binaryMTime"]?.int ?? 0) }()
        let samePath = info["path"]?.string == bundledDaemon.resolvingSymlinksInPath().path
        guard !(samePath && abs(theirs - mine) < 1), !restartAttempted else { return false }
        restartAttempted = true   // one try per launch: a daemon too old to shut down is left running rather than looping
        if (info["liveSessions"]?.int ?? 0) > 0 {
            let a = NSAlert(); a.messageText = String(localized: "Krill was updated")
            a.informativeText = String(localized: "The background service is still the previous version. Restart it to finish the update — running agent sessions will end. You can also do it later from the Krill menu.")
            a.addButton(withTitle: String(localized: "Restart Service")); a.addButton(withTitle: String(localized: "Later"))
            guard runAsSheet(a) == .alertFirstButtonReturn else { return false }
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
        let dir = binDir
        let p = Process(); p.executableURL = dir.appendingPathComponent("krilld")
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func refresh() async {
        guard let c = client else { return }
        // Assign only what changed: every assignment re-renders the views that read it.
        if let r = try? await c.call("repo.list", as: [Repo].self), r != repos { repos = r }
        if let w = try? await c.call("worktree.list", as: [Worktree].self), w != worktrees { worktrees = w }
        if let s = try? await c.call("session.list", as: [Session].self), s != sessions { sessions = s }
        onChange.forEach { $0() }
    }

    private func handle(_ method: String, _ p: JSONValue) {
        switch method {
        case "event.output":
            if let id = p["session"]?.string, let b = p["data"]?.string, let d = Data(base64Encoded: b) { outputHandlers[id]?(d) }
        case "event.session":
            guard let s = try? p.decode(Session.self) else { return }
            let old = sessions.first { $0.id == s.id }
            if old != s { upsert(s) }
            NotificationCenter.default.post(name: .krillSession, object: s.id)
            onSessionStatus.forEach { $0(s, old) }
            onChange.forEach { $0() }
            if old?.status != s.status, s.status == .done || s.status == .waiting, s.agent != "shell" { readContext(s.id) }
        case "event.devserver":
            if let w = p["worktree"]?.string, let u = p["url"]?.string {
                NotificationCenter.default.post(name: .krillDevServerURL, object: nil, userInfo: ["worktree": w, "url": u])
            }
        case "event.changed":
            Task { await refresh() }
        case "event.clone":
            NotificationCenter.default.post(name: .krillClone, object: nil, userInfo: ["id": p["id"]?.string ?? "", "line": p["line"]?.string ?? ""])
        case "event.settings":
            if case .object(let o)? = p["settings"] { SettingsStore.shared.apply(o) }
        case "event.ui":
            UIRequests.handle(p)
        default: break
        }
    }

    private func readContext(_ id: String) {
        Task {
            guard let u = try? await client?.call("session.contextWindow", .obj(["id": .string(id)])),
                  let used = u["used"]?.int, let window = u["window"]?.int, window > 0 else { return }
            let share = Double(used) / Double(window)
            if abs((contextShare[id] ?? -1) - share) > 0.01 { contextShare[id] = share; onChange.forEach { $0() } }
        }
    }

    // MARK: calls

    /// Errors show as a banner, never a blocking alert.
    @discardableResult
    func call(_ method: String, _ params: JSONValue? = nil) async -> JSONValue? {
        do { return try await client?.call(method, params) }
        catch {
            Banner.show((error as? RPCError)?.message ?? error.localizedDescription, style: .error)
            return nil
        }
    }

    /// Like `call`, but a failure comes back as its message (for actions that offer a way out) instead of a banner.
    func tryCall(_ method: String, _ params: JSONValue? = nil) async -> (value: JSONValue?, error: String?) {
        guard let c = client else { return (nil, "Krill's background service isn't running.") }
        do { return (try await c.call(method, params), nil) }
        catch { return (nil, (error as? RPCError)?.message ?? error.localizedDescription) }
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
