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
    /// How full each agent's conversation is (0…1), read when its status changes and while it works (Claude Code transcripts).
    var contextShare: [String: Double] = [:]
    @ObservationIgnored var agents: [AgentManifest] = AgentManifest.load()

    @ObservationIgnored private var outputHandlers: [String: (Data) -> Void] = [:]
    /// `event.session`s handled so far, per session: a list asked for before one of them may be older than it.
    @ObservationIgnored private var sessionEvents: [String: Int] = [:]
    /// The refresh under way, and whether another was asked for meanwhile (a burst of `event.changed` makes one more).
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false

    /// Workspaces of a project in the order they were opened: Workspace 1, 2, 3… (older ones on their own branch
    /// included), unless dragged into another in the sidebar.
    func workspaces(of r: Repo) -> [Worktree] {
        ordered(worktrees.filter { $0.repoId == r.id && !$0.archived }.sorted { $0.createdAt < $1.createdAt })
    }

    /// Projects as the sidebar lists them: by name, unless dragged into another order.
    var projects: [Repo] { ordered(repos.filter { !ScratchWindow.isScratch($0) }) }

    /// Project and workspace ids in the order they were dragged into in the sidebar; ones never moved follow them.
    var order: [String] = [] { didSet { UIState["sidebar.order"] = try? .from(order) } }
    /// Puts these (siblings) in this order.
    func reorder(_ ids: [String]) { order = ids + order.filter { !ids.contains($0) } }
    private func ordered<T: Identifiable>(_ xs: [T]) -> [T] where T.ID == String {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return xs.enumerated().sorted { (rank[$0.1.id] ?? .max, $0.0) < (rank[$1.1.id] ?? .max, $1.0) }.map(\.1)
    }

    func upsert(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
    }

    /// Tells the daemon what's on screen, so agents can ask (`kelp ui state`). Every tab and focus change calls it:
    /// a burst sends one notification, and only when the state differs from the last one sent.
    func publishUIState() {
        guard !publishQueued else { return }
        publishQueued = true
        DispatchQueue.main.async { [self] in publishQueued = false; sendUIState() }
    }
    @ObservationIgnored private var publishQueued = false
    @ObservationIgnored private var published: JSONValue?

    private func sendUIState() {
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
        guard state != published else { return }
        published = state
        c.notify("ui.publish", .obj(["state": state]))
    }

    /// One connection at a time: launch, a dropped connection and Restart Background Service all come through here.
    func connect() async {
        if client != nil { return }
        if let c = connecting { return await c.value }
        let c = Task { await open() }
        connecting = c
        await c.value
        connecting = nil
    }
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var retryDelay = 1.0
    @ObservationIgnored private var failing = false

    /// Up to ~5 s for the first connection (and the lists it brings), for things asked for at launch.
    func waitForConnection() async {
        for _ in 0..<50 where !connected { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private func open() async {
        for attempt in 0..<2 {
            if let c = try? RPCClient() { client = c; break }
            if attempt == 0 { launchDaemon() }
            for _ in 0..<30 { try? await Task.sleep(for: .milliseconds(100)); if let c = try? RPCClient() { client = c; break } }
            if client != nil { break }
        }
        guard let c = client else {
            // Keeps trying (less and less often); every action meanwhile says why it does nothing.
            if !failing { failing = true; Banner.show(Self.noService, style: .error, action: (String(localized: "Try Again"), { Task { await AppModel.shared.connect() } })) }
            reconnectSoon(); return
        }
        retryDelay = 1; failing = false
        // Before anything that waits (the version check can show a sheet): a daemon that drops meanwhile is still noticed.
        listen(c)
        c.onClose = { [weak self] in Task { @MainActor in
            guard let self, self.client === c else { return }   // a newer connection took over: nothing to undo
            self.client = nil; self.connected = false; self.reconnectSoon()
        } }
        if await checkDaemonVersion(c) { return }
        await UIState.load(c)
        if UIState.strings("sidebar.order") != order { order = UIState.strings("sidebar.order") }
        await SettingsStore.shared.load()
        await refresh()
        connected = client === c   // after the lists: what waits for the connection finds the projects in
        published = nil   // a new daemon knows nothing yet
        publishUIState()
        watchContext()
    }

    static let noService = String(localized: "Kelp's background service isn't running.")

    private var restartAttempted = false
    /// Where kelpd and kelp sit next to the app binary.
    private var binDir: URL { (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent() }
    private var bundledDaemon: URL { binDir.appendingPathComponent("kelpd") }

    /// After an app update the running daemon may be older. Restart it right away when no agent is running;
    /// otherwise ask, because restarting ends running sessions. Returns true when a restart is in progress.
    private func checkDaemonVersion(_ c: RPCClient) async -> Bool {
        guard let mine = (try? FileManager.default.attributesOfItem(atPath: bundledDaemon.path)[.modificationDate] as? Date)?.timeIntervalSince1970 else { return false }
        let info: DaemonInfo.Result
        do { info = try await c.call(DaemonInfo()) } catch let e as RPCError where e.code == RPCError.methodNotFound.code {
            let live = ((try? await c.call("session.list").array) ?? []).filter { $0["status"]?.string != "exited" }.count
            info = .init(path: "", binaryMTime: nil, pid: 0, liveSessions: live)   // predates daemon.info
        } catch { return false }
        // Older daemons don't report binaryMTime (and their "mtime" was read from disk, i.e. already the new file): restart them.
        let samePath = info.path == bundledDaemon.resolvingSymlinksInPath().path
        guard !(samePath && abs((info.binaryMTime ?? 0) - mine) < 1), !restartAttempted else { return false }
        restartAttempted = true   // one try per launch: a daemon too old to shut down is left running rather than looping
        if info.liveSessions > 0 {
            let a = NSAlert(); a.messageText = String(localized: "Kelp was updated")
            a.informativeText = String(
                localized: "The background service is still the previous version. Restart it to finish the update — running agent sessions will end. You can also do it later from the Kelp menu.")
            a.addButton(withTitle: String(localized: "Restart Service")); a.addButton(withTitle: String(localized: "Later"))
            // Return keeps the agents running: ending them takes a deliberate click.
            a.buttons[0].hasDestructiveAction = true; a.buttons[0].keyEquivalent = ""; a.buttons[1].keyEquivalent = "\r"
            guard runAsSheet(a) == .alertFirstButtonReturn else { return false }
        }
        _ = try? await c.call("daemon.shutdown")
        c.close(); client = nil
        try? await Task.sleep(for: .milliseconds(600))
        await open()
        return true
    }

    func restartDaemon() async {
        let old = client
        old?.onClose = nil   // this restart reconnects itself: a second client would hear every event twice
        client = nil; connected = false
        _ = try? await old?.call("daemon.shutdown"); old?.close()
        try? await Task.sleep(for: .milliseconds(600)); await connect()
    }

    private func reconnectSoon() {
        let wait = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        Task { try? await Task.sleep(for: .seconds(wait)); await connect() }
    }

    private func launchDaemon() {
        let dir = binDir
        let p = Process(); p.executableURL = dir.appendingPathComponent("kelpd")
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// One at a time: two lists asked for together could come back the older last. A caller gets a list read after it asked.
    func refresh() async {
        if let running = refreshTask { refreshAgain = true; await running.value; return }
        let t = Task { @MainActor in
            repeat { refreshAgain = false; await refreshOnce() } while refreshAgain
            refreshTask = nil   // with the last check: no await between, so a later caller starts a new one
        }
        refreshTask = t
        await t.value
    }

    private func refreshOnce() async {
        guard let c = client else { return }
        // Assign only what changed: every assignment re-renders the views that read it.
        if let r = try? await c.call("repo.list", as: [Repo].self), r != repos { repos = r }
        if let w = try? await c.call("worktree.list", as: [Worktree].self), w != worktrees { worktrees = w }
        let before = sessionEvents
        if let s = try? await c.call("session.list", as: [Session].self) {
            let merged = Self.merge(list: s, local: sessions, newer: Set(sessionEvents.keys.filter { sessionEvents[$0] != before[$0] }))
            if merged != sessions { sessions = merged }
        }
    }

    /// The daemon's list, except sessions in `newer`: an event about them came while the list was on its way (on the
    /// same connection, so after the list was read, or as it was), and what it said stays.
    static func merge(list: [Session], local: [Session], newer: Set<String>) -> [Session] {
        let kept = Dictionary(local.filter { newer.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let listed = Set(list.map(\.id))
        return list.map { kept[$0.id] ?? $0 } + local.filter { kept[$0.id] != nil && !listed.contains($0.id) }
    }

    /// The daemon's events, handled on the main actor.
    func listen(_ c: RPCClient) { c.onNotification = { [weak self] m, p in Task { @MainActor in self?.handle(m, p) } } }

    private func handle(_ method: String, _ p: JSONValue) {
        switch method {
        case "event.output":
            if let id = p["session"]?.string, let b = p["data"]?.string, let d = Data(base64Encoded: b) { outputHandlers[id]?(d) }
        case "event.session":
            guard let s = try? p.decode(Session.self) else { return }
            sessionEvents[s.id, default: 0] += 1
            let old = sessions.first { $0.id == s.id }
            if old != s { upsert(s) }   // views follow `sessions`
            (NSApp.delegate as? AppDelegate)?.notifier.statusChanged(s, old)
            if old?.status != s.status, s.agent != "shell" { readContext(s.id) }
        case "event.devserver":
            // A dev server in the workspace on screen printed its URL: the page opens beside it.
            // The keys stay where they are: the page comes while you may be typing.
            if let w = p["worktree"]?.string, let u = p["url"]?.string, w == Workbench.shared.workspaceId { Workbench.open(u, split: .right, workspace: w, focus: false) }
        case "event.changed":
            Task { await refresh() }
        case "event.clone":
            CloneSheet.cloneProgress(id: p["id"]?.string, line: p["line"]?.string)
        case "event.settings":
            if case .object(let o)? = p["settings"] { SettingsStore.shared.apply(o) }
        case "event.ui":
            UIRequests.handle(p)
        default: break
        }
    }

    /// No answer (not Claude Code, ended, just compacted by an older Claude Code) takes the ring away.
    private func readContext(_ id: String) {
        Task {
            guard let c = client else { return }
            do {
                let share = try await c.call(SessionContextWindow(id: id)).flatMap { $0.window > 0 ? Double($0.used) / Double($0.window) : nil }
                if abs((contextShare[id] ?? -1) - (share ?? -1)) > 0.01 { contextShare[id] = share }
            } catch {}   // no reply at all: the ring stays
        }
    }

    /// Agents already running when the app opens, and every working one now and then: a long turn fills the context too.
    private func watchContext() {
        guard contextWatch == nil else { return }
        contextWatch = Task { [weak self] in
            var first = true
            while !Task.isCancelled, let self {
                // Not while no window shows the rings (each read is a 1 MB transcript tail per working agent).
                if first || NSApp.occlusionState.contains(.visible) {
                    for s in sessions where s.agent != "shell" && s.status != .exited && (first || s.status == .working) { readContext(s.id) }
                }
                first = false
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
    @ObservationIgnored private var contextWatch: Task<Void, Never>?

    // MARK: calls

    /// Errors show as a banner, never a blocking alert.
    @discardableResult
    func call(_ method: String, _ params: JSONValue? = nil) async -> JSONValue? {
        guard let c = client else { Banner.show(Self.noService, style: .error); return nil }
        do { return try await c.call(method, params) }
        catch {
            Banner.show((error as? RPCError)?.message ?? error.localizedDescription, style: .error)
            return nil
        }
    }
    @discardableResult
    func call<M: RPCMethod>(_ m: M) async -> M.Result? {
        guard let c = client else { Banner.show(Self.noService, style: .error); return nil }
        do { return try await c.call(m) }
        catch { Banner.show((error as? RPCError)?.message ?? error.localizedDescription, style: .error); return nil }
    }

    /// Like `call`, but a failure comes back as its message (for actions that offer a way out) instead of a banner.
    func tryCall(_ method: String, _ params: JSONValue? = nil) async -> (value: JSONValue?, error: String?) {
        guard let c = client else { return (nil, Self.noService) }
        do { return (try await c.call(method, params), nil) }
        catch { return (nil, (error as? RPCError)?.message ?? error.localizedDescription) }
    }
    func tryCall<M: RPCMethod>(_ m: M) async -> (value: M.Result?, error: String?) {
        guard let c = client else { return (nil, Self.noService) }
        do { return (try await c.call(m), nil) }
        catch { return (nil, (error as? RPCError)?.message ?? error.localizedDescription) }
    }

    /// Replays history, then streams live output into `sink`.
    /// The daemon sends the history before any live output, but the two reach the main actor by different hops: live
    /// output that gets here first waits, so the screen shows the history and then what followed it.
    func attach(session id: String, sink: @escaping (Data) -> Void) async {
        earlyOutput[id] = []
        outputHandlers[id] = { [weak self] d in self?.earlyOutput[id]?.append(d) }
        if let r = try? await client?.call("session.attach", .obj(["id": .string(id)])),
           let h = r["history"]?.string, let d = Data(base64Encoded: h) { sink(d) }
        (earlyOutput.removeValue(forKey: id) ?? []).forEach(sink)
        if outputHandlers[id] != nil { outputHandlers[id] = sink }   // not if it was detached meanwhile
    }
    @ObservationIgnored private var earlyOutput: [String: [Data]] = [:]
    func detach(session id: String) { outputHandlers[id] = nil; Task { _ = try? await client?.call("session.detach", .obj(["id": .string(id)])) } }
    func write(session id: String, _ d: Data) { client?.notify("session.write", .obj(["id": .string(id), "base64": .string(d.base64EncodedString())])) }
    /// A notification, sent in call order and applied in that order: the last size is the one the terminal keeps.
    func resize(session id: String, cols: Int, rows: Int) { client?.notify("session.resize", .obj(["id": .string(id), "cols": .int(cols), "rows": .int(rows)])) }

    func worktree(_ id: String?) -> Worktree? { worktrees.first { $0.id == id } }
    func repo(_ id: String?) -> Repo? { repos.first { $0.id == id } }
    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }
}
