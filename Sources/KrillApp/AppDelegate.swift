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

        sidebar.onSelectWorktree = { [weak self] w in self?.content.show(worktree: w?.id) }
        sidebar.onSelectSession = { [weak self] s in self?.openSession(s.id) }
        notifier.onOpen = { [weak self] id in self?.openSession(id) }
        notifier.start()
        AppModel.shared.onChange.append { [weak self] in self?.content.workspace.refresh() }
        NotificationCenter.default.addObserver(forName: .krillRefresh, object: nil, queue: .main) { _ in Task { @MainActor in await AppModel.shared.refresh() } }
        buildMenu()
        Task {
            await AppModel.shared.connect()
            _ = await Accounts.load()
            sidebar.reload()
            let pick = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WORKTREE"].flatMap { b in AppModel.shared.worktrees.first { $0.branch == b } }
            if let w = pick ?? AppModel.shared.worktrees.first(where: { !$0.archived }) { sidebar.select(worktree: w.id); content.show(worktree: w.id) }
            if AppModel.shared.repos.isEmpty { addProject() }
        }
        NSApp.activate()
        if let out = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT"] { snapshotLater(out) }
    }


    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }   // daemon keeps sessions alive

    func isViewing(session id: String) -> Bool {
        window.isKeyWindow && content.currentMode == "Terminals" && content.workspace.currentSessionId == id
    }

    func open(worktree id: String) {
        sidebar.reload(); sidebar.select(worktree: id); content.show(worktree: id)
    }

    func openSession(_ id: String) {
        guard let s = AppModel.shared.session(id), let wid = s.worktreeId else { return }
        if content.worktreeId != wid { sidebar.select(worktree: wid); content.show(worktree: wid) }
        content.select(named: "Terminals")
        content.workspace.focus(session: id)
        Task { await AppModel.shared.call("session.markRead", .obj(["id": .string(id)])) }
    }

    // MARK: actions
    @objc func addProject() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.message = "Choose a git repository"
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { _ = await AppModel.shared.call("repo.add", .obj(["path": .string(u.path)])) }
    }

    @objc func newWorktree() {
        guard let repo = sidebar.selectedRepo else { addProject(); return }
        guard let branch = prompt("New worktree", "Branch name (created from \(repo.baseBranch)):"), !branch.isEmpty else { return }
        Task {
            guard let w = await AppModel.shared.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": .string(branch)])),
                  let id = w["id"]?.string else { return }
            await AppModel.shared.refresh()
            sidebar.reload(); sidebar.select(worktree: id); content.show(worktree: id)
        }
    }

    func startSession(agent: String?, command: String? = nil, newTab: Bool, shell: Bool = false) {
        guard let wid = content.worktreeId else { NSSound.beep(); return }
        var p: [String: JSONValue] = ["worktreeId": .string(wid)]
        if let command { p["command"] = .string(command) } else if !shell { p["agent"] = .string(agent ?? defaultAgent) } else { p["agent"] = "shell" }
        if !shell, command == nil, UserDefaults.standard.string(forKey: "permissionMode") == "yolo" { p["mode"] = "yolo" }
        Task {
            guard let r = await AppModel.shared.call("session.create", .object(p)), let s = try? r.decode(Session.self) else { return }
            content.select(named: "Terminals")
            content.workspace.add(session: s, newTab: newTab)
        }
    }

    @objc func newAgent() { startSession(agent: nil, newTab: true) }
    @objc func newTask() { if let r = sidebar.selectedRepo { AgentActions.newTask(repo: r) } else { addProject() } }
    @objc func newAgentSheet() { if let w = content.worktreeId { AgentActions.newAgent(worktree: w) } else { NSSound.beep() } }
    @objc func newAgentNamed(_ m: NSMenuItem) { startSession(agent: m.representedObject as? String, newTab: true) }
    @objc func newShellTab() { startSession(agent: nil, newTab: true, shell: true) }
    @objc func newCustom() { if let c = prompt("Run command", "Any CLI agent or command:"), !c.isEmpty { startSession(agent: nil, command: c, newTab: true) } }
    @objc func splitRight() { if content.workspace.split(vertical: true) { startSession(agent: nil, newTab: false, shell: true) } }
    @objc func splitDown() { if content.workspace.split(vertical: false) { startSession(agent: nil, newTab: false, shell: true) } }
    @objc func closePane() {
        if content.currentMode == "Files" { content.files.closeTab(); return }
        if content.currentMode == "Browser" { content.browser.closeTab(); return }
        if let s = content.workspace.currentSessionId { content.workspace.close(pane: s) }
    }
    @objc func showTasks() { content.select(named: "Tasks") }
    @objc func showBrowser() { content.select(named: "Browser") }
    @objc func toggleDesign() { content.select(named: "Browser"); content.browser.toggleDesign() }
    @objc func showFiles() { content.select(named: "Files") }
    @objc func goToLine() { content.select(named: "Files"); content.files.goToLine() }
    @objc func findInWorktree() { content.select(named: "Files"); content.files.focusSearch() }
    @objc func sendSelection() { content.files.sendSelectionToAgent() }
    @objc func openExternal() { content.files.openInExternalEditor() }
    @objc func markdownNote() { content.files.markdownNote() }
    @objc func jumpToDefinition() { content.files.jumpToDefinition() }
    @objc func showHover() { content.files.showHover() }
    @objc func nextPane() { content.workspace.focusNeighbor(step: 1) }
    @objc func prevPane() { content.workspace.focusNeighbor(step: -1) }
    @objc func selectTab(_ m: NSMenuItem) { content.workspace.selectTab(m.tag - 1) }
    @objc func floatingTerminal() { FloatingTerminal.shared.toggle() }
    @objc func quickOpen() { QuickOpen.shared.show(commandsOnly: false) }
    @objc func commandPalette() { QuickOpen.shared.show(commandsOnly: true) }
    @objc func showHistory() { HistoryWindow.shared.show() }
    @objc func showDashboard() { DashboardController.shared.show() }
    @objc func showTerminals() { content.select(named: "Terminals") }
    @objc func showReview() { content.select(named: "Review") }
    @objc func runDevServer() {
        guard let wid = content.worktreeId else { return }
        Task {
            guard let r = await AppModel.shared.call("worktree.run", .obj(["id": .string(wid)])), let s = try? r.decode(Session.self) else { return }
            content.workspace.add(session: s, newTab: true)
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
        let i = menu.addItem(withTitle: title, action: sel, keyEquivalent: key); i.keyEquivalentModifierMask = mods
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
        _ = item(file, "Add Project…", #selector(addProject), "o")
        _ = item(file, "New Worktree…", #selector(newWorktree), "n", [.command, .shift])
        file.addItem(.separator())
        _ = item(file, "Close Pane", #selector(closePane), "w")

        let agent = sub("Agent")
        _ = item(agent, "New Task…", #selector(newTask), "n")
        _ = item(agent, "New Agent…", #selector(newAgentSheet), "n", [.command, .option])
        _ = item(agent, "New Default Agent", #selector(newAgent), "n", [.command, .control])
        for a in AppModel.shared.agents { let i = item(agent, "New \(a.name)", #selector(newAgentNamed(_:))); i.representedObject = a.id }
        agent.addItem(.separator())
        _ = item(agent, "New Shell Tab", #selector(newShellTab), "t")
        _ = item(agent, "Run Command…", #selector(newCustom), "t", [.command, .shift])
        _ = item(agent, "Run Dev Server", #selector(runDevServer), "r", [.command, .control])
        agent.addItem(.separator())
        _ = item(agent, "Fan-out…", #selector(fanout), "f", [.command, .option])
        _ = item(agent, "Compare Fan-out…", #selector(compareFanout))
        agent.addItem(.separator())
        let def = NSMenu(); for a in AppModel.shared.agents { let i = item(def, a.name, #selector(setDefaultAgent(_:))); i.representedObject = a.id }
        let di = agent.addItem(withTitle: "Default Agent", action: nil, keyEquivalent: ""); agent.setSubmenu(def, for: di)

        let edit = sub("Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        _ = item(edit, "Find in Worktree…", #selector(findInWorktree), "f", [.command, .shift])
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
        view.addItem(.separator())
        _ = item(view, "Floating Terminal", #selector(floatingTerminal), "`", [.control])
        _ = item(view, "Quick Open…", #selector(quickOpen), "p")
        _ = item(view, "Command Palette…", #selector(commandPalette), "p", [.command, .shift])
        _ = item(view, "Agents Dashboard", #selector(showDashboard), "d", [.command, .option])
        _ = item(view, "Session History", #selector(showHistory), "h", [.command, .shift])
        _ = item(view, "Terminals", #selector(showTerminals), "0")
        _ = item(view, "Review Changes", #selector(showReview), "r", [.command, .shift])
        _ = item(view, "Files", #selector(showFiles), "e", [.command, .shift])
        _ = item(view, "Browser", #selector(showBrowser), "b", [.command, .shift])
        _ = item(view, "Tasks (GitHub & Linear)", #selector(showTasks), "i", [.command, .shift])
        _ = item(view, "Design Mode", #selector(toggleDesign), "d", [.command, .control])
        view.addItem(.separator())
        for i in 1...9 { let m = item(view, "Tab \(i)", #selector(selectTab(_:)), "\(i)"); m.tag = i }
        registerMoreMenus?(main)

        let win = sub("Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
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

