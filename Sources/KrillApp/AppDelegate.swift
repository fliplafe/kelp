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
        ScratchWindow.shared.registerHotKey()
        notifier.start()
        AppModel.shared.onChange.append { [weak self] in self?.main.editors.refresh() }
        NotificationCenter.default.addObserver(forName: .krillRefresh, object: nil, queue: .main) { _ in Task { @MainActor in await AppModel.shared.refresh() } }
        NotificationCenter.default.addObserver(forName: .krillDevServerURL, object: nil, queue: .main) { n in
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
            let pick = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WORKTREE"].flatMap { b in AppModel.shared.worktrees.first { $0.id == b || $0.branch == b || $0.note == b } }
            let last = UserDefaults.standard.string(forKey: "lastWorkspace").flatMap { AppModel.shared.worktree($0) }
            // Next turn of the run loop: the sidebar lays out its new rows before it gets a selection.
            try? await Task.sleep(for: .milliseconds(30))
            if let w = pick ?? last ?? AppModel.shared.worktrees.first(where: { !$0.archived }) { Workbench.show(workspace: w.id) }
            if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT"] == nil { OnboardingSheet.showIfFirstLaunch() }
        }
        NSApp.activate()
        if let out = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT"] { snapshotLater(out) }
    }

    /// Agents installed while Krill was in the background show up when it comes back.
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

    /// Folders dropped on the Dock icon or opened with `open -a Krill <path>` become projects; files open as tabs.
    func application(_ app: NSApplication, open urls: [URL]) {
        for u in urls {
            if u.scheme == "krill" { KrillLinks.handle(u); continue }
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
    @objc func toggleZoom() { editor?.toggleZoom() }
    @objc func equalizePanes() { editor?.equalizePanes() }
    @objc func focusPaneToward(_ m: NSMenuItem) { NSRectEdge(rawValue: UInt(m.tag)).map { editor?.focusGroup(toward: $0) } }
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
    @objc func revealInFinder() { WorkspaceActions.revealCurrent() }
    @objc func nextWorkspace() { Workbench.showWorkspace(offset: 1) }
    @objc func prevWorkspace() { Workbench.showWorkspace(offset: -1) }
    @objc func selectWorkspace(_ m: NSMenuItem) { Workbench.showWorkspace(number: m.tag) }
    @objc func nextNeedingAttention() { Workbench.showNextNeedingAttention() }
    @objc func showUsage() { Workbench.open("usage:") }
    @objc func showScratch() { ScratchWindow.shared.toggle() }
    @objc func workspaceBack() { Workbench.goBack(-1) }
    @objc func switchWorkspace() { WorkspaceSwitcher.shared.step(1) }
    @objc func switchWorkspaceBack() { WorkspaceSwitcher.shared.step(-1) }
    @objc func workspaceForward() { Workbench.goBack(1) }
    @objc func toggleInspector() { main.toggleInspectorPanel() }
    @objc func toggleSidebar() { main.toggleSidebarPanel() }
    @objc func toggleFocusMode() { main.toggleFocusMode() }
    @objc func showPanel(_ m: NSMenuItem) { if let id = m.representedObject as? String { main.showInspector(panel: id) } }
    @objc func runCommand(_ m: NSMenuItem) { if let id = m.representedObject as? String { ExtensionRegistry.shared.command(id)?.run([:]) } }
    @objc func quickOpen() { QuickOpen.shared.show(commandsOnly: false) }
    @objc func commandPalette() { QuickOpen.shared.show(commandsOnly: true) }
    @objc func showHistory() { HistoryWindow.shared.show() }
    @objc func openSettings() { SettingsWindow.show() }
    @objc func openExtensions() { SettingsWindow.show(section: "extensions") }
    /// Terminal and editor text zoom together, like a browser; the settings stay the one source.
    private func zoomText(_ step: Double?) {
        let s = SettingsStore.shared
        for key in ["terminal.fontSize", "editor.fontSize"] {
            s.set(key, .double(step.map { min(40, max(8, (s.number(key) ?? 13) + $0)) } ?? 13))
        }
    }
    @objc func biggerText() { zoomText(1) }
    @objc func smallerText() { zoomText(-1) }
    @objc func defaultText() { zoomText(nil) }
    @objc func openHelp() { Workbench.open(TabURI.file(Help.file.path)) }
    @objc func openExtensionGuide() { Workbench.open(TabURI.file(ExtensionRegistry.userDir.appendingPathComponent("EXTENSIONS.md").path)) }
    @objc func goToLine() { if let f = fileTab, let s = prompt(String(localized: "Go to line"), ""), let n = Int(s) { f.goTo(line: n) } }
    @objc func jumpToDefinition() { fileTab?.jumpToDefinition() }
    @objc func findInWorkspace() {
        main.showInspector(panel: "files")
        DispatchQueue.main.async { NotificationCenter.default.post(name: .krillFindInFiles, object: nil) }   // after the panel is built
    }
    /// ⌥⌘↩: "path:12-30" into the agent's prompt (it reads the file itself), without pressing Return.
    @objc func sendSelection() {
        guard let f = fileTab else { NSSound.beep(); return }
        FileActions.sendToAgent(f.path, lines: f.selectedText?.isEmpty == false ? f.selectedLines : nil)
    }
    @objc func copyWebLink() {
        guard let f = fileTab else { NSSound.beep(); return }
        FileActions.copyWebLink(f.path, lines: f.selectedLines)
    }
    @objc func copyReference() {
        guard let f = fileTab else { NSSound.beep(); return }
        FileActions.copyReference(f.path, lines: f.selectedText?.isEmpty == false ? f.selectedLines : nil)
    }
    @objc func restartService() {
        let a = NSAlert(); a.messageText = String(localized: "Restart the background service?"); a.informativeText = String(localized: "Running agent sessions end. Workspaces, history and settings are kept.")
        a.addButton(withTitle: String(localized: "Restart")); a.addButton(withTitle: String(localized: "Cancel"))
        Task { if await runSheet(a) == .alertFirstButtonReturn { await AppModel.shared.restartDaemon() } }
    }

    private let archivedMenu = ArchivedMenu()

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
        // The standard application menu: Services, Hide / Hide Others / Show All, Quit.
        let services = NSMenu(title: "Services"); NSApp.servicesMenu = services
        app.setSubmenu(services, for: app.addItem(withTitle: "Services", action: nil, keyEquivalent: ""))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Krill", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
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
        _ = item(file, "Reveal in Finder", #selector(revealInFinder), "r", [.command, .option])
        let openIn = NSMenu()
        WorkspaceActions.addOpenIn(to: openIn, path: { AppModel.shared.worktree(Workbench.shared.workspaceId)?.path }, prefix: "")
        if !openIn.items.isEmpty { file.setSubmenu(openIn, for: file.addItem(withTitle: "Open Workspace In", action: nil, keyEquivalent: "")) }
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
        // Find, as in every Mac editor: the panel, next / previous, use selection.
        let find = NSMenu(title: "Find")
        for (title, key, mods, action) in [("Find…", "f", NSEvent.ModifierFlags.command, NSFindPanelAction.showFindPanel),
                                           ("Find Next", "g", [.command], .next), ("Find Previous", "G", [.command, .shift], .previous),
                                           ("Use Selection for Find", "e", [.command], .setFindString)] {
            let i = find.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods; i.tag = Int(action.rawValue)
        }
        _ = item(find, "Find in Workspace…", #selector(findInWorkspace), "f", [.command, .shift])
        edit.setSubmenu(find, for: edit.addItem(withTitle: "Find", action: nil, keyEquivalent: ""))
        _ = item(edit, "Go to Line…", #selector(goToLine), "l")
        _ = item(edit, "Jump to Definition", #selector(jumpToDefinition), "j", [.command, .control])
        _ = item(edit, "Send to Agent", #selector(sendSelection), "\r", [.command, .option])
        _ = item(edit, "Copy Path and Line", #selector(copyReference), "c", [.command, .option, .shift])
        _ = item(edit, "Copy Web Link", #selector(copyWebLink))

        let view = sub("View")
        _ = item(view, "Show Sidebar", #selector(toggleSidebar), "0")
        _ = item(view, "Show Inspector", #selector(toggleInspector), "0", [.command, .option])
        _ = item(view, "Focus Mode", #selector(toggleFocusMode), "z", [.command, .control])
        for (i, p) in ExtensionRegistry.shared.all.panels.prefix(9).enumerated() {
            let m = item(view, "  " + p.title, #selector(showPanel(_:)), "\(i + 1)", [.command, .option]); m.representedObject = p.id
            m.image = .symbol(p.icon)
        }
        view.addItem(.separator())
        _ = item(view, "Bigger Text", #selector(biggerText), "+")
        // ⌘= enlarges too, as in Ghostty, VS Code and Safari (+ is the shifted =).
        let bigger = item(view, "Bigger Text", #selector(biggerText), "="); bigger.isHidden = true; bigger.allowsKeyEquivalentWhenHidden = true
        _ = item(view, "Smaller Text", #selector(smallerText), "-")
        _ = item(view, "Default Text Size", #selector(defaultText))
        view.addItem(.separator())
        _ = item(view, "Split Right", #selector(splitRight), "d")
        _ = item(view, "Split Down", #selector(splitDown), "d", [.command, .shift])
        _ = item(view, "Maximize Pane", #selector(toggleZoom), "\r", [.command, .shift])
        _ = item(view, "Equalize Panes", #selector(equalizePanes))
        let panes = NSMenu(title: "Select Pane")
        _ = item(panes, "Next Pane", #selector(nextGroup), "]")
        _ = item(panes, "Previous Pane", #selector(prevGroup), "[")
        panes.addItem(.separator())
        // NSLeftArrowFunctionKey…: ⌥⌘ arrows, as Ghostty moves between splits
        for (title, key, edge) in [("Pane on the Left", "\u{F702}", NSRectEdge.minX), ("Pane on the Right", "\u{F703}", .maxX),
                                   ("Pane Above", "\u{F700}", .maxY), ("Pane Below", "\u{F701}", .minY)] {
            item(panes, title, #selector(focusPaneToward(_:)), key, [.command, .option]).tag = Int(edge.rawValue)
        }
        view.setSubmenu(panes, for: view.addItem(withTitle: "Select Pane", action: nil, keyEquivalent: ""))
        view.addItem(.separator())
        _ = item(view, "Next Tab", #selector(nextTab), "]", [.command, .shift])
        _ = item(view, "Previous Tab", #selector(prevTab), "[", [.command, .shift])
        for i in 1...9 { let m = item(view, "Tab \(i)", #selector(selectTab(_:)), "\(i)"); m.tag = i; m.isHidden = i > 3; m.allowsKeyEquivalentWhenHidden = true }
        // ⌃Tab / ⌃⇧Tab: the workspace switcher (Window menu); tabs keep ⇧⌘] / ⇧⌘[.
        view.addItem(.separator())
        _ = item(view, "Command Palette…", #selector(commandPalette), "p", [.command, .shift])
        _ = item(view, "Open Quickly…", #selector(quickOpen), "p")
        _ = item(view, "Session History", #selector(showHistory), "h", [.command, .shift])
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        // Commands from extensions (built-in ones are already in the menus above).
        // Extension commands (Extensions… itself is in the Krill menu, next to Settings).
        let menuIds: Set<String> = ["agents.new", "terminal.new", "terminal.splitRight", "terminal.splitDown", "files.quickOpen"]
        let cmds = ExtensionRegistry.shared.all.commands.filter { !menuIds.contains($0.id) }
        let tools = cmds.isEmpty ? NSMenu() : sub("Tools")
        for c in cmds {
            let i = tools.addItem(withTitle: c.title, action: #selector(runCommand(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = c.id
            if let k = c.key.flatMap(Self.parseKey) { i.keyEquivalent = k.0; i.keyEquivalentModifierMask = k.1 }
        }

        ScriptsMenu.shared.fill(sub("Run")) { m, t, sel, key, mods in item(m, t, sel, key, mods) }

        let win = sub("Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        _ = item(win, "Show Agent Needing You", #selector(nextNeedingAttention), "u", [.command, .shift])
        _ = item(win, "Usage", #selector(showUsage), "u", [.command, .option])
        _ = item(win, "Scratch", #selector(showScratch), "k", [.command, .option, .control])
        // NSUpArrowFunctionKey / NSDownArrowFunctionKey
        _ = item(win, "Switch Workspace", #selector(switchWorkspace), "\t", .control)
        let back = item(win, "", #selector(switchWorkspaceBack), "\t", [.control, .shift]); back.isHidden = true; back.allowsKeyEquivalentWhenHidden = true
        _ = item(win, "Next Workspace", #selector(nextWorkspace), "\u{F701}", [.command, .control])
        _ = item(win, "Previous Workspace", #selector(prevWorkspace), "\u{F700}", [.command, .control])
        // NSLeftArrowFunctionKey / NSRightArrowFunctionKey: back and forward through the workspaces you visited.
        _ = item(win, "Back", #selector(workspaceBack), "\u{F702}", [.command, .control])
        _ = item(win, "Forward", #selector(workspaceForward), "\u{F703}", [.command, .control])
        for i in 1...9 { let m = item(win, "Workspace \(i)", #selector(selectWorkspace(_:)), "\(i)", .control); m.tag = i; m.isHidden = i > 1; m.allowsKeyEquivalentWhenHidden = true }
        win.addItem(.separator())
        let archived = NSMenu(title: "Archived Workspaces"); archived.delegate = archivedMenu
        win.setSubmenu(archived, for: win.addItem(withTitle: "Archived Workspaces", action: nil, keyEquivalent: ""))
        win.addItem(.separator())
        win.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win

        // Help: macOS puts its menu search here.
        let help = sub("Help")
        _ = item(help, "How Krill Works", #selector(openHelp), "?")
        _ = item(help, "Writing Extensions", #selector(openExtensionGuide))
        NSApp.helpMenu = help
        Localize.menu(mainMenu)           // shown in the user's language; the English titles stay the items' ids
        KeyBindings.apply(to: mainMenu)   // Settings › Keyboard's changes over the defaults
        NSApp.mainMenu = mainMenu
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Show/Hide items say what choosing them does; Focus Mode is ticked while it's on.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSidebar): item.title = main.sidebarShown ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
        case #selector(toggleInspector): item.title = main.inspectorShown ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")
        case #selector(toggleFocusMode): item.state = main.inFocusMode ? .on : .off
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
