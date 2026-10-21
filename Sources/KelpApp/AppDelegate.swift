import AppKit
import Core
import Agents
import Sparkle
import WorkbenchKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var main: MainWindowController!
    let notifier = Notifier()
    /// Files and links opened while Kelp starts (nil once it has).
    private var pendingOpens: [URL]? = []
    /// Sparkle needs a real app bundle (feed URL and keys live in Info.plist); dev runs skip it.
    lazy var updater: SPUStandardUpdaterController? = Bundle.main.bundleIdentifier == nil ? nil
        : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        Self.watchHangs()
        LatinShortcuts.install()
        // Kelp no longer ships example extensions; remove the copies older versions wrote into its home.
        try? FileManager.default.removeItem(at: Paths.root.appendingPathComponent("bundled-extensions"))
        Perf.measure("registry") { ExtensionRegistry.shared.reload() }
        Perf.measure("window") { main = MainWindowController() }
        Perf.measure("show") { main.showWindow(nil) }
        notifier.onOpen = { id in Workbench.focus(session: id) }
        ScratchWindow.shared.registerHotKey()
        notifier.start()
        buildMenu()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.trackGlances() } }
        track(owner: self) { ExtensionRegistry.shared.revision } changed: { [weak self] _ in self?.buildMenu() }
        track(owner: self) { AgentAvailability.shared.ids } changed: { [weak self] _ in self?.buildMenu() }
        track(owner: self) { SettingsStore.shared.value("keys") } changed: { [weak self] _ in self?.buildMenu() }
        ExtensionRegistry.shared.watch()
        // Extension commands and requirement checks need the user's PATH; reading it can take seconds.
        DispatchQueue.global(qos: .utility).async {
            _ = LoginPath.value
            DispatchQueue.main.async { MainActor.assumeIsolated { ExtensionRegistry.pathReady = true; ExtensionRegistry.shared.reload() } }
        }
        Task {
            await AppModel.shared.connect()
            ExtensionRegistry.shared.reload()   // settings (disabled extensions) are known now
            AgentAvailability.shared.refresh(force: true)
            _ = await Accounts.load()
            let pick = ProcessInfo.processInfo.environment["KELP_SNAPSHOT_WORKTREE"].flatMap { b in AppModel.shared.worktrees.first { $0.id == b || $0.branch == b || $0.note == b } }
            let last = UIState["workbench.lastWorkspace"]?.string.flatMap { AppModel.shared.worktree($0) }
            // Next turn of the run loop: the sidebar lays out its new rows before it gets a selection.
            try? await Task.sleep(for: .milliseconds(30))
            if let w = pick ?? last ?? AppModel.shared.worktrees.first(where: { !$0.archived }) { Workbench.show(workspace: w.id) }
            let early = pendingOpens ?? []; pendingOpens = nil
            if !early.isEmpty { application(NSApp, open: early) }
            if ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] == nil { OnboardingSheet.showIfFirstLaunch() }
        }
        NSApp.activate()
        if let out = ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] { snapshotLater(out) }
    }

    /// Agents installed while Kelp was in the background show up when it comes back.
    func applicationDidBecomeActive(_ n: Notification) { AgentAvailability.shared.refresh(); notifier.checkAllowed() }

    /// Unsaved files ask before quitting, like any Mac app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let edited = main?.editors.editedFiles ?? []
        guard !edited.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = edited.count == 1 ? String(localized: "Do you want to save the changes you made to “\(edited[0].title)”?")
            : String(localized: "You have \(edited.count) files with unsaved changes. Save them before quitting?")
        a.informativeText = String(localized: "Your changes will be lost if you don't save them.")
        a.addButton(withTitle: edited.count == 1 ? String(localized: "Save") : String(localized: "Save All"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.addButton(withTitle: String(localized: "Don't Save"))
        switch runAsSheet(a) {
        case .alertFirstButtonReturn: return edited.allSatisfy { $0.save() } ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }   // the daemon keeps sessions alive
    func applicationWillTerminate(_ n: Notification) { main?.leaveFocusMode() }

    /// Folders dropped on the Dock icon or opened with `open -a Kelp <path>` become projects; files open as tabs.
    /// What opens Kelp waits for the projects and the last workspace to be on screen.
    func application(_ app: NSApplication, open urls: [URL]) {
        if pendingOpens != nil { pendingOpens? += urls; return }
        for u in urls {
            if u.scheme == "kelp" { KelpLinks.handle(u); continue }
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
            if dir.boolValue { Workbench.addProject(path: u.path) } else { Workbench.open(TabURI.file(u.path)) }
        }
    }

    /// Right-click on the Dock icon: the agents waiting for you, like Mail's dock menu offers what's new.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        for s in AttentionQueue.sessions {
            let place = AppModel.shared.worktree(s.worktreeId)?.displayName ?? ""
            let state = s.status == .waiting ? String(localized: "needs you") : String(localized: "finished")
            let i = m.add("\(AgentCatalog.displayName(s)) — \(state) · \(place)") { NSApp.activate(); Workbench.focus(session: s.id) }
            i.image = AgentCatalog.icon(s.agent, size: 16)
        }
        if !m.items.isEmpty { m.addItem(.separator()) }
        m.add(String(localized: "New Workspace")) { NSApp.activate(); Workbench.newWorkspace() }
        return m
    }

    /// A finished agent counts as read once its pane has been on screen in the front window for a second: a glance,
    /// not a click. Opening a workspace in passing doesn't clear anything; questions and failures wait for an answer.
    private var glanced: [String: Date] = [:]
    private func trackGlances() {
        guard NSApp.isActive, let w = main?.window, w.isKeyWindow, w.occlusionState.contains(.visible), let e = Workbench.editor else { glanced = [:]; return }
        let shown = Set(e.visibleSessions)
        glanced = glanced.filter { shown.contains($0.key) }
        for sid in shown {
            guard let s = AppModel.shared.session(sid), s.unread, s.status == .done || (s.status == .exited && !s.endedWithError) else { glanced[sid] = nil; continue }
            let since = glanced[sid] ?? Date()
            glanced[sid] = since
            guard Date().timeIntervalSince(since) >= 1 else { continue }
            glanced[sid] = nil
            Task { await AppModel.shared.call("session.markRead", .obj(["id": .string(sid)])) }
        }
    }

    /// No notification for an agent whose tab the user is looking at.
    func isViewing(session id: String) -> Bool {
        main.window?.isKeyWindow == true && Workbench.editor?.layout.focusedGroup?.selectedTab?.uri == TabURI.session(id)
    }

    // MARK: menu
    /// A menu item (the menu bar's or the sidebar's Add Project menu) runs the command its identifier names.
    @objc func runCommand(_ sender: Any?) {
        guard let id = (sender as? NSUserInterfaceItemIdentification)?.identifier?.rawValue else { return }
        Self.run(id)
    }
    static func run(_ id: String, _ args: [String: JSONValue] = [:]) { ExtensionRegistry.shared.command(id)?.run(args) }

    let archivedMenu = ArchivedMenu()

    /// The command's menu item: its identifier is the command id (Settings › Keyboard, `validateMenuItem`).
    func item(_ c: CommandSpec) -> NSMenuItem {
        let i = NSMenuItem(title: c.title, action: #selector(runCommand(_:)), keyEquivalent: "")
        i.target = self; i.identifier = NSUserInterfaceItemIdentifier(c.id)
        if let k = c.key.flatMap(KeySpec.init) { i.keyEquivalent = k.key; i.keyEquivalentModifierMask = k.mods.flags }
        return i
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Show/Hide items say what choosing them does; Focus Mode is ticked while it's on; Stop needs something running;
    /// the file commands need a file.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.identifier?.rawValue {
        case "workbench.toggleSidebar": item.title = main.sidebarShown ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
        case "workbench.toggleInspector": item.title = main.inspectorShown ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")
        case "workbench.toggleFocusMode": item.state = main.inFocusMode ? .on : .off
        case "power.keepAwake": item.state = SettingsStore.shared.string("power.keepAwake") == "always" ? .on : .off
        case "scripts.run", "scripts.test", "scripts.edit": return Workbench.shared.workspaceId != nil
        case "scripts.stop": return ScriptsMenu.shared.canStop
        // Off elsewhere, so a terminal still gets their keys.
        case "editor.runFile", "editor.testAtCursor", "editor.format": return Workbench.editor?.focusedContent is FileTab
        default: break
        }
        return true
    }
}

/// Window › Archived Workspaces. The list is read from the daemon whenever the workspaces change, so the menu fills at once.
@MainActor
final class ArchivedMenu: NSObject, NSMenuDelegate {
    private var archived: [Worktree] = []
    override init() {
        super.init()
        track(owner: self) { AppModel.shared.worktrees } changed: { [weak self] _ in Task { await self?.reload() } }
    }
    private func reload() async {
        archived = ((try? await AppModel.shared.client?.call("worktree.list", .obj(["archived": true]), as: [Worktree].self)) ?? []).filter(\.archived)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !archived.isEmpty else { menu.addItem(withTitle: String(localized: "None"), action: nil, keyEquivalent: "").isEnabled = false; return }
        for w in archived.sorted(by: { $0.createdAt > $1.createdAt }) {
            menu.add("\(w.displayName) — \(AppModel.shared.repo(w.repoId)?.name ?? "")") { WorkspaceActions.unarchive(w.id) }
        }
    }
}
