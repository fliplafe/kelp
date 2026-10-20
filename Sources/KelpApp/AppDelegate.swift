import AppKit
import Core
import Agents
import Sparkle
import WorkbenchKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var main: MainWindowController!
    let notifier = Notifier()
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
        AppModel.shared.onChange.append { [weak self] in self?.main.editors.refresh() }
        NotificationCenter.default.addObserver(forName: .kelpRefresh, object: nil, queue: .main) { _ in Task { @MainActor in await AppModel.shared.refresh() } }
        NotificationCenter.default.addObserver(forName: .kelpDevServerURL, object: nil, queue: .main) { n in
            guard let wid = n.userInfo?["worktree"] as? String, let url = n.userInfo?["url"] as? String else { return }
            MainActor.assumeIsolated { if wid == Workbench.shared.workspaceId { Workbench.open(url, split: .right) } }
        }
        buildMenu()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.trackGlances() } }
        track { ExtensionRegistry.shared.revision } changed: { [weak self] _ in self?.buildMenu() }
        track { AgentAvailability.shared.ids } changed: { [weak self] _ in self?.buildMenu() }
        track { SettingsStore.shared.value("keys") } changed: { [weak self] _ in self?.buildMenu() }
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
        a.addButton(withTitle: edited.count == 1 ? String(localized: "Save") : String(localized: "Save All")); a.addButton(withTitle: String(localized: "Cancel")); a.addButton(withTitle: String(localized: "Don't Save"))
        switch runAsSheet(a) {
        case .alertFirstButtonReturn: return edited.allSatisfy { $0.save() } ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }   // the daemon keeps sessions alive
    func applicationWillTerminate(_ n: Notification) { main?.leaveFocusMode() }

    /// Folders dropped on the Dock icon or opened with `open -a Kelp <path>` become projects; files open as tabs.
    func application(_ app: NSApplication, open urls: [URL]) {
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
            let i = m.add("\(AgentCatalog.displayName(s)) — \(s.status == .waiting ? "needs you" : "finished") · \(place)") { NSApp.activate(); Workbench.focus(session: s.id) }
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
    /// A menu item (or the sidebar's Add Project button) runs the command its identifier names.
    @objc func runCommand(_ sender: Any?) {
        guard let id = (sender as? NSUserInterfaceItemIdentification)?.identifier?.rawValue else { return }
        Self.run(id)
    }
    private static func run(_ id: String, _ args: [String: JSONValue] = [:]) { ExtensionRegistry.shared.command(id)?.run(args) }

    private let archivedMenu = ArchivedMenu()

    /// The command's menu item: its identifier is the command id (Settings › Keyboard, `validateMenuItem`).
    private func item(_ c: CommandSpec) -> NSMenuItem {
        let i = NSMenuItem(title: c.title, action: #selector(runCommand(_:)), keyEquivalent: "")
        i.target = self; i.identifier = NSUserInterfaceItemIdentifier(c.id)
        if let k = c.key.flatMap(KeySpec.init) { i.keyEquivalent = k.key; i.keyEquivalentModifierMask = k.mods.flags }
        return i
    }

    /// The menu bar is laid out here by command id, like Zed's app menus; titles, keys and actions come from the
    /// registry. Commands it doesn't place (extensions', the other built-ins') go in the menu they name, Tools by default.
    func buildMenu() {
        let mainMenu = NSMenu(), reg = ExtensionRegistry.shared
        var placed: Set<String> = []
        func sub(_ title: String) -> NSMenu {
            let mi = mainMenu.addItem(withTitle: title, action: nil, keyEquivalent: ""); let m = NSMenu(title: title); mainMenu.setSubmenu(m, for: mi); return m
        }
        /// These commands, in order ("-" is a separator); one whose extension is off is left out.
        @discardableResult func add(_ m: NSMenu, _ ids: String...) -> [NSMenuItem] {
            ids.compactMap { id in
                if id == "-" { m.addItem(.separator()); return nil }
                guard let c = reg.command(id) else { return nil }
                placed.insert(id)
                let i = item(c); m.addItem(i); return i
            }
        }
        /// Only its key: in the menu so the shortcut works, not shown.
        func hide(_ i: NSMenuItem) { i.isHidden = true; i.allowsKeyEquivalentWhenHidden = true }

        let app = sub("Kelp")
        app.addItem(withTitle: "About Kelp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let u = updater { app.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "").target = u }
        add(app, "-", "workbench.openSettings", "workbench.openExtensions", "workbench.restartService", "-")
        // The standard application menu: Services, Hide / Hide Others / Show All, Quit.
        let services = NSMenu(title: "Services"); NSApp.servicesMenu = services
        app.setSubmenu(services, for: app.addItem(withTitle: "Services", action: nil, keyEquivalent: ""))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Kelp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Kelp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = sub("File")
        add(file, "workspace.new", "agents.new", "terminal.new")
        let with = NSMenu()
        for a in AgentCatalog.installed(AgentCatalog.all) { with.add(a.name) { Self.run("agents.new", ["agent": .string(a.id)]) } }
        with.addItem(.separator())
        for e in reg.all.editors {
            with.add(e.title, symbol: e.icon) { e.open(IDEContext.current) }
        }
        file.setSubmenu(with, for: file.addItem(withTitle: "New Tab", action: nil, keyEquivalent: ""))
        add(file, "workspace.addProject", "-", "workspace.revealInFinder")
        let openIn = NSMenu()
        WorkspaceActions.addOpenIn(to: openIn, path: { AppModel.shared.worktree(Workbench.shared.workspaceId)?.path }, prefix: "")
        if !openIn.items.isEmpty { file.setSubmenu(openIn, for: file.addItem(withTitle: "Open Workspace In", action: nil, keyEquivalent: "")) }
        add(file, "-", "editor.save", "editor.saveAll", "-", "editor.closeTab", "workspace.close")

        let edit = sub("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        // Find, as in every Mac editor: the panel, next / previous, use selection.
        let find = NSMenu(title: "Find")
        for (title, key, mods, action) in [("Find…", "f", NSEvent.ModifierFlags.command, NSFindPanelAction.showFindPanel),
                                           ("Find Next", "g", [.command], .next), ("Find Previous", "G", [.command, .shift], .previous),
                                           ("Use Selection for Find", "e", [.command], .setFindString)] {
            let i = find.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods; i.tag = Int(action.rawValue)
        }
        add(find, "files.findInWorkspace")
        edit.setSubmenu(find, for: edit.addItem(withTitle: "Find", action: nil, keyEquivalent: ""))
        add(edit, "editor.goToLine", "editor.jumpToDefinition", "editor.sendToAgent", "editor.copyReference", "editor.copyWebLink")

        let view = sub("View")
        add(view, "workbench.toggleSidebar", "workbench.toggleInspector", "workbench.toggleFocusMode")
        for (i, p) in reg.all.panels.prefix(9).enumerated() {
            let m = view.add("  " + p.title, symbol: p.icon, key: "\(i + 1)") { Self.run("workbench.showPanel", ["panel": .string(p.id)]) }
            m.keyEquivalentModifierMask = [.command, .option]
        }
        placed.insert("workbench.showPanel")
        add(view, "-", "view.biggerText")
        // ⌘= enlarges too, as in Ghostty, VS Code and Safari (+ is the shifted =).
        hide(view.add("Bigger Text", key: "=") { Self.run("view.biggerText") })
        add(view, "view.smallerText", "view.defaultTextSize", "-", "terminal.splitRight", "terminal.splitDown", "view.maximizePane", "view.equalizePanes")
        let panes = NSMenu(title: "Select Pane")
        add(panes, "view.nextPane", "view.previousPane", "-", "view.paneLeft", "view.paneRight", "view.paneAbove", "view.paneBelow")
        view.setSubmenu(panes, for: view.addItem(withTitle: "Select Pane", action: nil, keyEquivalent: ""))
        add(view, "-", "editor.nextTab", "editor.previousTab")
        for n in 1...9 { add(view, "editor.tab.\(n)").forEach { $0.isHidden = n > 3; $0.allowsKeyEquivalentWhenHidden = true } }
        // ⌃Tab / ⌃⇧Tab: the workspace switcher (Window menu); tabs keep ⇧⌘] / ⇧⌘[.
        add(view, "-", "workbench.commandPalette", "files.quickOpen", "agents.history", "-")
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        let tools = sub("Tools")   // filled last, with what nothing else placed

        let runs = sub("Run")
        runs.delegate = ScriptsMenu.shared   // the project's other commands go between the separators
        add(runs, "scripts.run", "scripts.test", "scripts.stop", "-", "-", "scripts.edit")

        let win = sub("Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        add(win, "agents.nextNeedingYou", "agents.usage", "workbench.scratch", "workspace.switch")
        let back = win.add("", key: "\t") { Self.run("workspace.switch", ["by": -1]) }
        back.keyEquivalentModifierMask = [.control, .shift]; hide(back)
        add(win, "workspace.next", "workspace.previous", "workspace.back", "workspace.forward")
        for n in 1...9 { add(win, "workspace.select.\(n)").forEach { $0.isHidden = n > 1; $0.allowsKeyEquivalentWhenHidden = true } }
        win.addItem(.separator())
        let archived = NSMenu(title: "Archived Workspaces"); archived.delegate = archivedMenu
        win.setSubmenu(archived, for: win.addItem(withTitle: "Archived Workspaces", action: nil, keyEquivalent: ""))
        win.addItem(.separator())
        win.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win

        // Help: macOS puts its menu search here.
        let help = sub("Help")
        add(help, "help.guide", "help.extensionGuide")
        NSApp.helpMenu = help

        var extended: Set<NSMenu> = []
        for c in reg.all.commands where !placed.contains(c.id) {
            let m = c.menu.flatMap { mainMenu.item(withTitle: $0)?.submenu } ?? tools
            if m !== tools, extended.insert(m).inserted { m.addItem(.separator()) }
            m.addItem(item(c))
        }
        if tools.items.isEmpty { mainMenu.removeItem(at: mainMenu.indexOfItem(withSubmenu: tools)) }
        KeyBindings.apply(to: mainMenu)   // Settings › Keyboard's changes over the defaults (on the English titles)
        Localize.menu(mainMenu)           // shown in the user's language
        NSApp.mainMenu = mainMenu
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Show/Hide items say what choosing them does; Focus Mode is ticked while it's on; Stop needs something running.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.identifier?.rawValue {
        case "workbench.toggleSidebar": item.title = main.sidebarShown ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
        case "workbench.toggleInspector": item.title = main.inspectorShown ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")
        case "workbench.toggleFocusMode": item.state = main.inFocusMode ? .on : .off
        case "scripts.run", "scripts.test", "scripts.edit": return Workbench.shared.workspaceId != nil
        case "scripts.stop": return ScriptsMenu.shared.canStop
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
        track { AppModel.shared.worktrees } changed: { [weak self] _ in Task { await self?.reload() } }
    }
    private func reload() async {
        archived = ((try? await AppModel.shared.client?.call("worktree.list", .obj(["archived": true]), as: [Worktree].self)) ?? []).filter(\.archived)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !archived.isEmpty else { menu.addItem(withTitle: "None", action: nil, keyEquivalent: "").isEnabled = false; return }
        for w in archived.sorted(by: { $0.createdAt > $1.createdAt }) {
            menu.add("\(w.displayName) — \(AppModel.shared.repo(w.repoId)?.name ?? "")") { WorkspaceActions.unarchive(w.id) }
        }
    }
}
