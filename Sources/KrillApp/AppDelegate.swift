import AppKit
import Core
import Agents
import Sparkle

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
        // Krill no longer ships example extensions; remove the copies older versions wrote into its home.
        try? FileManager.default.removeItem(at: Paths.root.appendingPathComponent("bundled-extensions"))
        Perf.measure("registry") { ExtensionRegistry.shared.reload() }
        Perf.measure("window") { main = MainWindowController() }
        Perf.measure("show") { main.showWindow(nil) }
        notifier.onOpen = { id in Workbench.focus(session: id) }
        notifier.start()
        AppModel.shared.onChange.append { [weak self] in self?.main.editors.refresh() }
        NotificationCenter.default.addObserver(forName: .krillRefresh, object: nil, queue: .main) { _ in Task { @MainActor in await AppModel.shared.refresh() } }
        NotificationCenter.default.addObserver(forName: .krillDevServerURL, object: nil, queue: .main) { n in
            guard let wid = n.userInfo?["worktree"] as? String, let url = n.userInfo?["url"] as? String else { return }
            MainActor.assumeIsolated { if wid == Workbench.shared.workspaceId { Workbench.open(url, split: .right) } }
        }
        buildMenu()
        track { ExtensionRegistry.shared.revision } changed: { [weak self] _ in self?.buildMenu() }
        track { AgentAvailability.shared.ids } changed: { [weak self] _ in self?.buildMenu() }
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
            AppModel.shared.startSubagentPolling()
            let pick = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WORKTREE"].flatMap { b in AppModel.shared.worktrees.first { $0.id == b || $0.branch == b || $0.note == b } }
            let last = UserDefaults.standard.string(forKey: "lastWorkspace").flatMap { AppModel.shared.worktree($0) }
            // Next turn of the run loop: the sidebar lays out its new rows before it gets a selection.
            try? await Task.sleep(for: .milliseconds(30))
            if let w = pick ?? last ?? AppModel.shared.worktrees.first(where: { !$0.archived }) { Workbench.show(workspace: w.id) }
        }
        NSApp.activate()
        if let out = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT"] { snapshotLater(out) }
    }

    /// Agents installed while Krill was in the background show up when it comes back.
    func applicationDidBecomeActive(_ n: Notification) { AgentAvailability.shared.refresh() }

    /// Unsaved files ask before quitting, like any Mac app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let edited = main?.editors.editedFiles ?? []
        guard !edited.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = edited.count == 1 ? "Do you want to save the changes you made to “\(edited[0].title)”?"
            : "You have \(edited.count) files with unsaved changes. Save them before quitting?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: edited.count == 1 ? "Save" : "Save All"); a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Don't Save")
        switch runAsSheet(a) {
        case .alertFirstButtonReturn: return edited.allSatisfy { $0.save() } ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }   // the daemon keeps sessions alive

    /// No notification for an agent whose tab the user is looking at.
    func isViewing(session id: String) -> Bool {
        main.window?.isKeyWindow == true && Workbench.editor?.layout.focusedGroup?.selectedTab?.uri == TabURI.session(id)
    }

    // MARK: actions (menus)
    private var editor: EditorArea? {
        if Workbench.editor == nil { NSSound.beep() }
        return Workbench.editor
    }
    private var fileTab: FileTab? { Workbench.editor?.focusedContent as? FileTab }

    @objc func newWorkspace() { Workbench.newWorkspace() }
    @objc func addProject() { Workbench.addProject() }
    @objc func newAgent() { editor?.newAgent() }
    @objc func newAgentNamed(_ m: NSMenuItem) { editor?.newAgent(m.representedObject as? String) }
    @objc func newTerminal() { editor?.newTerminal() }
    @objc func saveFile() { if let f = fileTab { f.save() } else { NSSound.beep() } }
    @objc func saveAll() { main.editors.editedFiles.forEach { $0.save() } }
    @objc func splitRight() { editor?.splitFocused(.right) }
    @objc func splitDown() { editor?.splitFocused(.down) }
    /// ⌘W: the focused tab; in a workspace with nothing open, the workspace itself.
    @objc func closeTab() {
        guard let e = editor else { return }
        if e.focusedContent == nil, let w = e.worktree { WorkspaceActions.close(w) } else { e.closeFocusedTab() }
    }
    @objc func closeWorkspace() { if let w = editor?.worktree { WorkspaceActions.close(w) } }
    @objc func nextTab() { editor?.cycleTab(1) }
    @objc func prevTab() { editor?.cycleTab(-1) }
    @objc func nextGroup() { editor?.focusGroup(1) }
    @objc func prevGroup() { editor?.focusGroup(-1) }
    @objc func selectTab(_ m: NSMenuItem) { editor?.selectTab(index: m.tag - 1) }
    @objc func toggleInspector() { main.toggleInspectorPanel() }
    @objc func toggleSidebar() { main.toggleSidebarPanel() }
    @objc func showPanel(_ m: NSMenuItem) { if let id = m.representedObject as? String { main.showInspector(panel: id) } }
    @objc func runCommand(_ m: NSMenuItem) { if let id = m.representedObject as? String { ExtensionRegistry.shared.command(id)?.run([:]) } }
    @objc func quickOpen() { QuickOpen.shared.show(commandsOnly: false) }
    @objc func commandPalette() { QuickOpen.shared.show(commandsOnly: true) }
    @objc func showHistory() { HistoryWindow.shared.show() }
    @objc func openSettings() { SettingsWindow.show() }
    @objc func openExtensions() { SettingsWindow.show(section: "extensions") }
    @objc func goToLine() { if let f = fileTab, let s = prompt("Go to line", ""), let n = Int(s) { f.goTo(line: n) } }
    @objc func jumpToDefinition() { fileTab?.jumpToDefinition() }
    @objc func findInWorkspace() { main.showInspector(panel: "files") }
    @objc func sendSelection() {
        guard let f = fileTab, let text = f.selectedText, let sid = Workbench.shared.focusedSession else { NSSound.beep(); return }
        let lines = f.selectedLines.map { $0.lowerBound == $0.upperBound ? "line \($0.lowerBound)" : "lines \($0.lowerBound)-\($0.upperBound)" } ?? ""
        Task { await AppModel.shared.call("session.send", .obj(["id": .string(sid), "text": .string("In \(f.path) \(lines):\n```\n\(text)\n```\n"), "enter": false])) }
        Workbench.focus(session: sid)
    }
    @objc func restartService() {
        let a = NSAlert(); a.messageText = "Restart the background service?"; a.informativeText = "Running agent sessions end. Workspaces, history and settings are kept."
        a.addButton(withTitle: "Restart"); a.addButton(withTitle: "Cancel")
        Task { if await runSheet(a) == .alertFirstButtonReturn { await AppModel.shared.restartDaemon() } }
    }

    // MARK: menu
    private func item(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        // Shifted letters as capitals: the form AppKit matches reliably (⇧⌘D, not ⌘D).
        let k = mods.contains(.shift) && key.count == 1 && key.first?.isLetter == true ? key.uppercased() : key
        let i = menu.addItem(withTitle: title, action: sel, keyEquivalent: k); i.keyEquivalentModifierMask = mods
        if sel != nil, i.target == nil { i.target = self }
        return i
    }

    /// "cmd+shift+k" → key equivalent and modifiers (extension commands declare keys this way).
    static func parseKey(_ s: String) -> (String, NSEvent.ModifierFlags)? {
        var mods: NSEvent.ModifierFlags = []
        var key = ""
        for part in s.lowercased().split(separator: "+") {
            switch part {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: key = String(part)
            }
        }
        guard !key.isEmpty else { return nil }
        return (mods.contains(.shift) && key.count == 1 ? key.uppercased() : key, mods)
    }

    func buildMenu() {
        let mainMenu = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let mi = mainMenu.addItem(withTitle: title, action: nil, keyEquivalent: ""); let m = NSMenu(title: title); mainMenu.setSubmenu(m, for: mi); return m
        }
        let app = sub("Krill")
        app.addItem(withTitle: "About Krill", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let u = updater { app.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "").target = u }
        app.addItem(.separator())
        _ = item(app, "Settings…", #selector(openSettings), ",")
        _ = item(app, "Extensions…", #selector(openExtensions), "")
        _ = item(app, "Restart Background Service…", #selector(restartService))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Krill", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Krill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = sub("File")
        _ = item(file, "New Workspace", #selector(newWorkspace), "n")
        _ = item(file, "New Agent", #selector(newAgent), "t", [.command, .option])
        _ = item(file, "New Terminal", #selector(newTerminal), "t")
        let with = NSMenu()
        for a in AgentCatalog.installed(AgentCatalog.all) { let i = item(with, a.name, #selector(newAgentNamed(_:))); i.representedObject = a.id }
        with.addItem(.separator())
        for e in ExtensionRegistry.shared.all.editors {
            with.add(e.title, symbol: e.icon) { e.open(IDEContext.current) }
        }
        file.setSubmenu(with, for: file.addItem(withTitle: "New Tab", action: nil, keyEquivalent: ""))
        _ = item(file, "Add Project…", #selector(addProject), "o")
        file.addItem(.separator())
        _ = item(file, "Save", #selector(saveFile), "s")
        _ = item(file, "Save All", #selector(saveAll), "s", [.command, .option])
        file.addItem(.separator())
        _ = item(file, "Close Tab", #selector(closeTab), "w")
        _ = item(file, "Close Workspace", #selector(closeWorkspace), "w", [.command, .shift])

        let edit = sub("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        _ = item(edit, "Find in Workspace…", #selector(findInWorkspace), "f", [.command, .shift])
        _ = item(edit, "Go to Line…", #selector(goToLine), "l")
        _ = item(edit, "Jump to Definition", #selector(jumpToDefinition), "j", [.command, .control])
        _ = item(edit, "Send Selection to Agent", #selector(sendSelection), "\r", [.command, .option])

        let view = sub("View")
        _ = item(view, "Show Sidebar", #selector(toggleSidebar), "0")
        _ = item(view, "Show Inspector", #selector(toggleInspector), "0", [.command, .option])
        for (i, p) in ExtensionRegistry.shared.all.panels.prefix(9).enumerated() {
            let m = item(view, "  " + p.title, #selector(showPanel(_:)), "\(i + 1)", [.command, .option]); m.representedObject = p.id
            m.image = .symbol(p.icon)
        }
        view.addItem(.separator())
        _ = item(view, "Split Right", #selector(splitRight), "d")
        _ = item(view, "Split Down", #selector(splitDown), "d", [.command, .shift])
        _ = item(view, "Next Tab", #selector(nextTab), "]", [.command, .shift])
        _ = item(view, "Previous Tab", #selector(prevTab), "[", [.command, .shift])
        _ = item(view, "Next Group", #selector(nextGroup), "]")
        _ = item(view, "Previous Group", #selector(prevGroup), "[")
        for i in 1...9 { let m = item(view, "Tab \(i)", #selector(selectTab(_:)), "\(i)"); m.tag = i; m.isHidden = i > 3; m.allowsKeyEquivalentWhenHidden = true }
        view.addItem(.separator())
        _ = item(view, "Command Palette…", #selector(commandPalette), "p", [.command, .shift])
        _ = item(view, "Open Quickly…", #selector(quickOpen), "p")
        _ = item(view, "Session History", #selector(showHistory), "h", [.command, .shift])
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        // Commands from extensions (built-in ones are already in the menus above).
        let tools = sub("Tools")
        _ = item(tools, "Manage Extensions…", #selector(openExtensions))
        let menuIds: Set<String> = ["agents.new", "terminal.new", "terminal.splitRight", "terminal.splitDown", "files.quickOpen"]
        let cmds = ExtensionRegistry.shared.all.commands.filter { !menuIds.contains($0.id) }
        if !cmds.isEmpty { tools.addItem(.separator()) }
        for c in cmds {
            let i = tools.addItem(withTitle: c.title, action: #selector(runCommand(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = c.id
            if let k = c.key.flatMap(Self.parseKey) { i.keyEquivalent = k.0; i.keyEquivalentModifierMask = k.1 }
        }

        let win = sub("Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win
        NSApp.mainMenu = mainMenu
    }
}
