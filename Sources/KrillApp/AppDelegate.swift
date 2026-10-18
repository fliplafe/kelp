import AppKit
import Core
import Agents
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let sidebar = SidebarViewController()
    let content = ContentViewController()
    let notifier = Notifier()
    /// Sparkle needs a real app bundle (feed URL and keys live in Info.plist); dev runs skip it.
    lazy var updater: SPUStandardUpdaterController? = Bundle.main.bundleIdentifier == nil ? nil
        : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    var defaultAgent: String { UserDefaults.standard.string(forKey: "defaultAgent") ?? "claude" }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        let split = NSSplitViewController()
        let sb = NSSplitViewItem(sidebarWithViewController: sidebar); sb.minimumThickness = 220; sb.maximumThickness = 420
        split.addSplitViewItem(sb); split.addSplitViewItem(NSSplitViewItem(viewController: content))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Krill"; window.contentViewController = split; window.setFrameAutosaveName("main"); window.center()
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.makeKeyAndOrderFront(nil)

        sidebar.onSelectWorktree = { [weak self] w in self?.content.show(worktree: w?.id); if let w { UserDefaults.standard.set(w.id, forKey: "lastWorktree") } }
        notifier.onOpen = { [weak self] id in self?.openSession(id) }
        notifier.start()
        AppModel.shared.onChange.append { [weak self] in self?.content.refresh() }
        NotificationCenter.default.addObserver(forName: .krillRefresh, object: nil, queue: .main) { _ in Task { @MainActor in await AppModel.shared.refresh() } }
        buildMenu()
        Task {
            await AppModel.shared.connect()
            _ = await Accounts.load()
            AppModel.shared.startSubagentPolling()
            sidebar.reload()
            let pick = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WORKTREE"].flatMap { b in AppModel.shared.worktrees.first { $0.branch == b } }
            let last = UserDefaults.standard.string(forKey: "lastWorktree").flatMap { AppModel.shared.worktree($0) }
            if let w = pick ?? last ?? AppModel.shared.worktrees.first(where: { !$0.archived }) { sidebar.select(worktree: w.id); content.show(worktree: w.id) }
            content.refresh()
        }
        NSApp.activate()
        if let out = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT"] { snapshotLater(out) }
    }


    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }   // daemon keeps sessions alive

    func isViewing(session id: String) -> Bool {
        guard window.isKeyWindow, let ws = content.workspace, case .terminal(let l)? = ws.selectedKind else { return false }
        return l.sessions.contains(id)
    }

    func open(worktree id: String) {
        sidebar.reload(); sidebar.select(worktree: id); content.show(worktree: id)
        UserDefaults.standard.set(id, forKey: "lastWorktree")
    }

    func openSession(_ id: String) {
        guard let s = AppModel.shared.session(id), let wid = s.worktreeId else { return }
        if content.worktreeId != wid { open(worktree: wid) }
        content.workspace?.focus(session: id)
        Task { await AppModel.shared.call("session.markRead", .obj(["id": .string(id)])) }
    }

    /// Local URLs (dev servers) open in the workspace's browser tab.
    func openInBrowser(_ url: URL) {
        guard let w = content.workspace else { NSWorkspace.shared.open(url); return }
        w.browserController.open(url.absoluteString, in: w.worktree.id, reuse: true)
    }

    /// Where commands that need a workspace go; beeps when none is open.
    private var ws: WorkspaceViewController? {
        if content.workspace == nil { NSSound.beep() }
        return content.workspace
    }

    // MARK: actions
    @objc func addProject() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose a git repository"; p.prompt = "Add Repository"
        guard p.runModal() == .OK, let u = p.url else { return }
        Task {
            guard await AppModel.shared.call("repo.add", .obj(["path": .string(u.path)])) != nil else { return }
            await AppModel.shared.refresh()
            if let r = AppModel.shared.repos.first(where: { URL(fileURLWithPath: $0.path).standardized == u.standardized }) { WorkspaceComposer.show(repo: r) }
        }
    }

    @objc func newWorktree() { WorkspaceComposer.show(repo: sidebar.selectedRepo) }
    @objc func newTask() { newWorktree() }

    /// A command line run in the current workspace (quick commands, Run Command…).
    func startSession(agent: String?, command: String? = nil, newTab: Bool, shell: Bool = false) {
        guard let w = ws else { return }
        guard let command else { w.newAgent(shell ? "shell" : agent ?? defaultAgent, split: !newTab); return }
        Task {
            guard let wid = content.worktreeId,
                  let r = await AppModel.shared.call("session.create", .obj(["worktreeId": .string(wid), "command": .string(command)])),
                  let s = try? r.decode(Session.self) else { return }
            content.workspace?.add(session: s)
        }
    }

    @objc func newAgent() { ws?.newAgent(defaultAgent) }
    @objc func newChat() { ws?.startChat() }
    @objc func newAgentSheet() { if let w = ws { AgentActions.newAgent(worktree: w.worktree.id) } }
    @objc func newAgentNamed(_ m: NSMenuItem) { ws?.newAgent(m.representedObject as? String ?? defaultAgent) }
    @objc func newShellTab() { ws?.newTerminal() }
    @objc func newCustom() { if ws != nil, let c = prompt("Run command", "Any CLI agent or command:"), !c.isEmpty { startSession(agent: nil, command: c, newTab: true) } }
    @objc func splitRight() { ws?.newTerminal(split: true, vertical: true) }
    @objc func splitDown() { ws?.newTerminal(split: true, vertical: false) }
    @objc func closePane() {
        guard let w = ws else { return }
        switch w.selectedKind {
        case .files?: w.filesController.closeTab()
        default: w.closeCurrent()
        }
    }
    @objc func closeTab() { ws?.closeCurrentTab() }
    @objc func showTasks() { ws?.open(.tasks) }
    @objc func showBrowser() { ws?.open(.browser) }
    @objc func toggleDesign() { ws?.browserController.toggleDesign() }
    @objc func showFiles() { ws?.open(.files) }
    @objc func goToLine() { ws?.filesController.goToLine() }
    @objc func findInWorktree() { ws?.filesController.focusSearch() }
    @objc func sendSelection() { content.workspace?.filesController.sendSelectionToAgent() }
    @objc func openExternal() { content.workspace?.filesController.openInExternalEditor() }
    @objc func markdownNote() { content.workspace?.filesController.markdownNote() }
    @objc func jumpToDefinition() { content.workspace?.filesController.jumpToDefinition() }
    @objc func showHover() { content.workspace?.filesController.showHover() }
    @objc func nextPane() { ws?.focusNeighbor(step: 1) }
    @objc func prevPane() { ws?.focusNeighbor(step: -1) }
    @objc func nextTab() { ws?.selectTab(offset: 1) }
    @objc func prevTab() { ws?.selectTab(offset: -1) }
    @objc func selectTab(_ m: NSMenuItem) { ws?.selectTab(index: m.tag - 1) }
    @objc func floatingTerminal() { FloatingTerminal.shared.toggle() }
    @objc func quickOpen() { QuickOpen.shared.show(commandsOnly: false) }
    @objc func commandPalette() { QuickOpen.shared.show(commandsOnly: true) }
    @objc func showHistory() { HistoryWindow.shared.show() }
    @objc func showDashboard() { DashboardController.shared.show() }
    @objc func showReview() { ws?.open(.changes) }
    @objc func runDevServer() {
        guard let wid = ws?.worktree.id else { return }
        Task {
            guard let r = await AppModel.shared.call("worktree.run", .obj(["id": .string(wid)])), let s = try? r.decode(Session.self) else { return }
            content.workspace?.add(session: s)
            NotificationCenter.default.post(name: .krillDevServer, object: wid)
        }
    }
    @objc func fanout() { if let r = sidebar.selectedRepo { FanoutController.start(repo: r) } else { addProject() } }
    @objc func compareFanout() {
        let g = FanoutController.groups()
        guard !g.isEmpty else { let a = NSAlert(); a.messageText = "No fan-out in progress"; a.runModal(); return }
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26)); pop.addItems(withTitles: g.keys.sorted())
        let a = NSAlert(); a.messageText = "Compare which fan-out?"; a.accessoryView = pop; a.addButton(withTitle: "Compare"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn, let k = pop.titleOfSelectedItem, let ws = g[k] else { return }
        FanoutController.show(ids: ws.map(\.id), title: k)
    }
    @objc func setDefaultAgent(_ m: NSMenuItem) { UserDefaults.standard.set(m.representedObject as? String, forKey: "defaultAgent") }

    // MARK: menu
    private func item(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        // Shifted letters as capitals: the form AppKit matches reliably (⇧⌘D, not ⌘D).
        let k = mods.contains(.shift) && key.count == 1 && key.first!.isLetter ? key.uppercased() : key
        let i = menu.addItem(withTitle: title, action: sel, keyEquivalent: k); i.keyEquivalentModifierMask = mods
        if sel != nil, i.target == nil, sel!.description.hasPrefix("terminate") == false { i.target = self }
        return i
    }

    func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let mi = main.addItem(withTitle: title, action: nil, keyEquivalent: ""); let m = NSMenu(title: title); main.setSubmenu(m, for: mi); return m
        }
        let app = sub("Krill")
        app.addItem(withTitle: "About Krill", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let u = updater {
            let i = app.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: ""); i.target = u
        }
        app.addItem(.separator())
        let prefs = item(app, "Settings…", #selector(openSettings), ","); _ = prefs
        _ = item(app, "Restart Background Service…", #selector(restartService))
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Krill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = sub("File")
        _ = item(file, "New Workspace…", #selector(newWorktree), "n")
        _ = item(file, "Add Repository…", #selector(addProject), "o")
        file.addItem(.separator())
        _ = item(file, "New Terminal Tab", #selector(newShellTab), "t")
        _ = item(file, "New Agent Tab", #selector(newAgent), "t", [.command, .option])
        let newIn = NSMenu()
        for a in AgentCatalog.installed(AppModel.shared.agents) { let i = item(newIn, a.name, #selector(newAgentNamed(_:))); i.representedObject = a.id }
        newIn.addItem(.separator())
        _ = item(newIn, "Agent with Options…", #selector(newAgentSheet), "n", [.command, .option])
        _ = item(newIn, "Chat with Claude", #selector(newChat), "c", [.command, .option])
        _ = item(newIn, "Command…", #selector(newCustom), "t", [.command, .shift])
        let ni = file.addItem(withTitle: "New Tab With", action: nil, keyEquivalent: ""); file.setSubmenu(newIn, for: ni)
        _ = item(file, "Run Dev Server", #selector(runDevServer), "r", [.command, .control])
        file.addItem(.separator())
        _ = item(file, "Fan Out Task…", #selector(fanout), "f", [.command, .option])
        _ = item(file, "Compare Fan-out…", #selector(compareFanout))
        let def = NSMenu(); for a in AgentCatalog.installed(AppModel.shared.agents) { let i = item(def, a.name, #selector(setDefaultAgent(_:))); i.representedObject = a.id }
        let di = file.addItem(withTitle: "Default Agent", action: nil, keyEquivalent: ""); file.setSubmenu(def, for: di)
        file.addItem(.separator())
        _ = item(file, "Close", #selector(closePane), "w")
        _ = item(file, "Close Tab", #selector(closeTab), "w", [.command, .shift])

        let edit = sub("Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        _ = item(edit, "Find in Workspace…", #selector(findInWorktree), "f", [.command, .shift])
        _ = item(edit, "Go to Line…", #selector(goToLine), "l")
        _ = item(edit, "Send Selection to Agent", #selector(sendSelection), "\r", [.command, .option])
        _ = item(edit, "Open in External Editor", #selector(openExternal), "o", [.command, .option])
        _ = item(edit, "Note to Agent on Selection", #selector(markdownNote), "a", [.command, .shift])
        _ = item(edit, "Jump to Definition", #selector(jumpToDefinition), "j", [.command, .control])
        _ = item(edit, "Show Quick Help", #selector(showHover), "h", [.command, .control])
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")

        let view = sub("View")
        _ = item(view, "Split Right", #selector(splitRight), "d")
        _ = item(view, "Split Down", #selector(splitDown), "d", [.command, .shift])
        _ = item(view, "Next Pane", #selector(nextPane), "]")
        _ = item(view, "Previous Pane", #selector(prevPane), "[")
        _ = item(view, "Next Tab", #selector(nextTab), "]", [.command, .shift])
        _ = item(view, "Previous Tab", #selector(prevTab), "[", [.command, .shift])
        view.addItem(.separator())
        _ = item(view, "Changes", #selector(showReview), "r", [.command, .shift])
        _ = item(view, "Files", #selector(showFiles), "e", [.command, .shift])
        _ = item(view, "Browser", #selector(showBrowser), "b", [.command, .shift])
        _ = item(view, "Issues & Pull Requests", #selector(showTasks), "i", [.command, .shift])
        _ = item(view, "Design Mode", #selector(toggleDesign), "d", [.command, .control])
        view.addItem(.separator())
        _ = item(view, "Jump To…", #selector(quickOpen), "j")
        _ = item(view, "Quick Open…", #selector(quickOpen), "p")
        _ = item(view, "Command Palette…", #selector(commandPalette), "p", [.command, .shift])
        _ = item(view, "Floating Terminal", #selector(floatingTerminal), "a", [.command, .option])
        _ = item(view, "Agents Dashboard", #selector(showDashboard), "d", [.command, .option])
        _ = item(view, "Session History", #selector(showHistory), "h", [.command, .shift])
        view.addItem(.separator())
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        for i in 1...9 { let m = item(view, "Tab \(i)", #selector(selectTab(_:)), "\(i)"); m.tag = i }
        registerMoreMenus?(main)

        let win = sub("Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
    var registerMoreMenus: ((NSMenu) -> Void)?
    @objc func restartService() {
        let a = NSAlert(); a.messageText = "Restart the background service?"; a.informativeText = "Running agent sessions will end. Worktrees, history and settings are kept."
        a.addButton(withTitle: "Restart"); a.addButton(withTitle: "Cancel")
        Task { if await runSheet(a) == .alertFirstButtonReturn { await AppModel.shared.restartDaemon() } }
    }
    @objc func openSettings() { SettingsWindow.show() }
}

extension Notification.Name { static let krillDevServer = Notification.Name("krill.devserver") }

