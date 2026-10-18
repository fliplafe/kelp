import AppKit
import Core
import Agents

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let sidebar = SidebarViewController()
    let content = ContentViewController()
    let notifier = Notifier()
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
            sidebar.reload()
            if let w = AppModel.shared.worktrees.first(where: { !$0.archived }) { sidebar.select(worktree: w.id); content.show(worktree: w.id) }
            if AppModel.shared.repos.isEmpty { addProject() }
        }
        NSApp.activate()
        if let out = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT"] { snapshotLater(out) }
    }

    /// Dev aid: KRILL_SNAPSHOT=/path.png writes the window contents and quits (works without screen-recording permission).
    /// KRILL_SNAPSHOT_MODE=Review|Terminals picks the mode first.
    private func snapshotLater(_ path: String) {
        NSApp.appearance = NSAppearance(named: .aqua)   // cacheDisplay mixes appearances otherwise
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [self] in
            window.setContentSize(NSSize(width: 1320, height: 840)); window.contentView?.layoutSubtreeIfNeeded()
            if let m = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_MODE"] { content.select(named: m) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(2) }
                v.cacheDisplay(in: v.bounds, to: rep)
                print("DIFF", content.diff.debugInfo)
                for p in content.workspace.view.allSubviews(of: PaneView.self) { print("PANE", p.sessionId.prefix(8), p.terminal.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)) }
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }   // daemon keeps sessions alive

    func isViewing(session id: String) -> Bool {
        window.isKeyWindow && content.currentMode == "Terminals" && content.workspace.currentSessionId == id
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
        var p: [String: JSONValue] = ["worktreeId": .string(wid), "cols": .int(content.workspace.currentSessionId.flatMap { _ in nil } ?? 120), "rows": 32]
        if let command { p["command"] = .string(command) } else if !shell { p["agent"] = .string(agent ?? defaultAgent) } else { p["agent"] = "shell" }
        Task {
            guard let r = await AppModel.shared.call("session.create", .object(p)), let s = try? r.decode(Session.self) else { return }
            content.select(named: "Terminals")
            content.workspace.add(session: s, newTab: newTab)
        }
    }

    @objc func newAgent() { startSession(agent: nil, newTab: true) }
    @objc func newAgentNamed(_ m: NSMenuItem) { startSession(agent: m.representedObject as? String, newTab: true) }
    @objc func newShellTab() { startSession(agent: nil, newTab: true, shell: true) }
    @objc func newCustom() { if let c = prompt("Run command", "Any CLI agent or command:"), !c.isEmpty { startSession(agent: nil, command: c, newTab: true) } }
    @objc func splitRight() { if content.workspace.split(vertical: true) { startSession(agent: nil, newTab: false, shell: true) } }
    @objc func splitDown() { if content.workspace.split(vertical: false) { startSession(agent: nil, newTab: false, shell: true) } }
    @objc func closePane() { if let s = content.workspace.currentSessionId { content.workspace.close(pane: s) } }
    @objc func nextPane() { content.workspace.focusNeighbor(step: 1) }
    @objc func prevPane() { content.workspace.focusNeighbor(step: -1) }
    @objc func selectTab(_ m: NSMenuItem) { content.workspace.selectTab(m.tag - 1) }
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
        app.addItem(.separator())
        let prefs = item(app, "Settings…", #selector(openSettings), ","); _ = prefs
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Krill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = sub("File")
        _ = item(file, "Add Project…", #selector(addProject), "o")
        _ = item(file, "New Worktree…", #selector(newWorktree), "n", [.command, .shift])
        file.addItem(.separator())
        _ = item(file, "Close Pane", #selector(closePane), "w")

        let agent = sub("Agent")
        _ = item(agent, "New Agent (default)", #selector(newAgent), "n")
        for a in AppModel.shared.agents { let i = item(agent, "New \(a.name)", #selector(newAgentNamed(_:))); i.representedObject = a.id }
        agent.addItem(.separator())
        _ = item(agent, "New Shell Tab", #selector(newShellTab), "t")
        _ = item(agent, "Run Command…", #selector(newCustom), "t", [.command, .shift])
        _ = item(agent, "Run Dev Server", #selector(runDevServer), "r", [.command, .control])
        agent.addItem(.separator())
        let def = NSMenu(); for a in AppModel.shared.agents { let i = item(def, a.name, #selector(setDefaultAgent(_:))); i.representedObject = a.id }
        let di = agent.addItem(withTitle: "Default Agent", action: nil, keyEquivalent: ""); agent.setSubmenu(def, for: di)

        let edit = sub("Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = sub("View")
        _ = item(view, "Split Right", #selector(splitRight), "d")
        _ = item(view, "Split Down", #selector(splitDown), "d", [.command, .shift])
        _ = item(view, "Next Pane", #selector(nextPane), "]")
        _ = item(view, "Previous Pane", #selector(prevPane), "[")
        view.addItem(.separator())
        _ = item(view, "Terminals", #selector(showTerminals), "0")
        _ = item(view, "Review Changes", #selector(showReview), "r", [.command, .shift])
        view.addItem(.separator())
        for i in 1...9 { let m = item(view, "Tab \(i)", #selector(selectTab(_:)), "\(i)"); m.tag = i }
        registerMoreMenus?(main)

        let win = sub("Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
    var registerMoreMenus: ((NSMenu) -> Void)?
    @objc func openSettings() { SettingsWindow.show() }
}

extension Notification.Name { static let krillDevServer = Notification.Name("krill.devserver") }

extension NSView {
    func allSubviews<T: NSView>(of t: T.Type) -> [T] { subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.allSubviews(of: t) } }
}
