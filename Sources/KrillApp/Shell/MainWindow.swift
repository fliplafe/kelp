import AppKit
import SwiftUI
import Core

/// The window: projects & agents | editor area | inspector, under a unified toolbar.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    let editors = EditorHost()
    let inspector = InspectorController()
    private let split = NSSplitViewController()
    private var inspectorItem: NSSplitViewItem!

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: w)
        let sb = NSSplitViewItem(sidebarWithViewController: SidebarController())
        sb.minimumThickness = 220; sb.maximumThickness = 400; sb.canCollapse = true
        let content = NSSplitViewItem(viewController: editors)
        content.minimumThickness = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 250; inspectorItem.maximumThickness = 520; inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = UserDefaults.standard.bool(forKey: "inspector.collapsed")
        [sb, content, inspectorItem].forEach(split.addSplitViewItem)
        split.splitView.autosaveName = "main.split"
        w.contentViewController = split
        w.title = "Krill"; w.setFrameAutosaveName("main"); w.delegate = self
        w.titlebarSeparatorStyle = .automatic
        let tb = NSToolbar(identifier: "main"); tb.delegate = self; tb.displayMode = .iconOnly; tb.allowsUserCustomization = false
        w.toolbar = tb; w.toolbarStyle = .unifiedCompact   // the title bar holds a title and two buttons: no need for a tall one
        if w.frame.origin == .zero { w.center() }
        track { AppModel.shared.worktree(Workbench.shared.workspaceId) } changed: { [weak self] _ in self?.updateTitle() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func showWorkspace(_ id: String?) {
        editors.show(id)
        updateTitle()
        AppModel.shared.publishUIState()
    }

    private func updateTitle() {
        guard let w = AppModel.shared.worktree(Workbench.shared.workspaceId), let r = AppModel.shared.repo(w.repoId) else {
            window?.title = "Krill"; window?.subtitle = ""; return
        }
        window?.title = w.displayName
        window?.subtitle = "\(r.name) · \(w.branch)"
        editors.current?.showEdited()   // a workspace with unsaved files keeps saying so after a switch
    }

    @objc func toggleInspectorPanel() {
        inspectorItem.animator().isCollapsed.toggle()
        UserDefaults.standard.set(inspectorItem.isCollapsed, forKey: "inspector.collapsed")
    }
    func showInspector(panel: String) {
        if inspectorItem.isCollapsed { toggleInspectorPanel() }
        inspector.show(panel: panel)
    }
    @objc func toggleSidebarPanel() { split.toggleSidebar(nil) }

    // MARK: toolbar
    // The one place to add a tab (like Safari's "+"); the empty workspace offers the same choices.
    private static let newTab = NSToolbarItem.Identifier("newTab"), inspectorToggle = NSToolbarItem.Identifier("inspector")
    private static let addProject = NSToolbarItem.Identifier("addProject")

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, Self.addProject, .sidebarTrackingSeparator, .flexibleSpace, Self.newTab,
         .inspectorTrackingSeparator, .flexibleSpace, Self.inspectorToggle]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.newTab:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.image = .symbol("plus", "New Tab"); i.label = "New Tab"; i.toolTip = "New agent, terminal, browser…"
            i.showsIndicator = false
            i.menu = NSMenu()
            i.menu.delegate = NewTabMenuSource.shared
            return i
        case Self.addProject:   // over the projects it adds to, where people look for it
            let i = NSToolbarItem(itemIdentifier: id)
            i.image = .symbol("folder.badge.plus", "Add Project"); i.label = "Add Project"; i.toolTip = "Add a project folder (⌘O)"
            i.target = NSApp.delegate; i.action = #selector(AppDelegate.addProject)
            return i
        case Self.inspectorToggle:
            let i = NSToolbarItem(itemIdentifier: id)
            i.image = .symbol("sidebar.trailing", "Inspector"); i.label = "Inspector"; i.toolTip = "Show or hide the inspector (⌥⌘0)"
            i.target = self; i.action = #selector(toggleInspectorPanel)
            return i
        default: return nil
        }
    }

    /// Closing the window quits (the daemon keeps agents running) — through the unsaved-files question; Cancel keeps it.
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
}

/// Fills the toolbar's "+" menu when it opens (agents installed now, extensions enabled now).
@MainActor
final class NewTabMenuSource: NSObject, NSMenuDelegate {
    static let shared = NewTabMenuSource()
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let e = Workbench.editor else { menu.addItem(withTitle: "Select a workspace first", action: nil, keyEquivalent: "").isEnabled = false; return }
        for i in e.newTabMenu(group: nil).items { i.menu?.removeItem(i); menu.addItem(i) }
    }
}

/// Holds one editor area per recently used workspace, so switching back is instant (terminals stay attached).
@MainActor
final class EditorHost: NSViewController {
    private var areas: [String: EditorArea] = [:]
    private var recent: [String] = []
    private(set) var current: EditorArea?
    var editedFiles: [FileTab] { areas.values.flatMap(\.editedFiles) }
    private var welcome: NSView?
    private static let keep = 4

    override func loadView() { view = NSView(); showWelcome() }

    func show(_ id: String?) {
        if let c = current, c.workspaceId == id { return }
        current?.view.removeFromSuperview()
        guard let id, AppModel.shared.worktree(id) != nil else { current = nil; showWelcome(); return }
        welcome?.removeFromSuperview(); welcome = nil
        let area = areas[id] ?? EditorArea(workspaceId: id)
        if areas[id] == nil { areas[id] = area; addChild(area) }
        recent.removeAll { $0 == id }; recent.insert(id, at: 0)
        // Their terminals detach; a workspace with unsaved files stays.
        for old in recent.dropFirst(Self.keep) where areas[old]?.editedFiles.isEmpty != false { areas[old]?.removeFromParent(); areas[old] = nil }
        recent = Array(recent.prefix(Self.keep))
        current = area
        area.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(area.view)
        NSLayoutConstraint.activate([area.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                                     area.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     area.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), area.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        area.reconcile()
        area.focusSelected()
    }

    /// Daemon state changed.
    func refresh() {
        for (id, a) in areas where AppModel.shared.worktree(id) == nil { a.view.removeFromSuperview(); a.removeFromParent(); areas[id] = nil; recent.removeAll { $0 == id } }
        if let c = current, areas[c.workspaceId] == nil { current = nil; showWelcome() }
        current?.reconcile()
        for (id, a) in areas where id != current?.workspaceId { a.reconcile() }
        if current == nil { showWelcome() }
    }

    private func showWelcome() {
        let hasRepos = !AppModel.shared.repos.isEmpty
        if let w = welcome as? WelcomeView, w.hasRepos == hasRepos { return }
        welcome?.removeFromSuperview()
        let w = WelcomeView(hasRepos: hasRepos)
        w.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(w)
        NSLayoutConstraint.activate([w.topAnchor.constraint(equalTo: view.topAnchor), w.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     w.leadingAnchor.constraint(equalTo: view.leadingAnchor), w.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        welcome = w
    }
}

/// No workspace selected: first-run guidance.
@MainActor
final class WelcomeView: NSView {
    let hasRepos: Bool
    init(hasRepos: Bool) {
        self.hasRepos = hasRepos
        super.init(frame: .zero)
        let icon = NSImageView(image: .symbol(hasRepos ? "sidebar.left" : "folder.badge.plus"))
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light); icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: hasRepos ? "Select a workspace" : "Welcome to Krill")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: hasRepos
            ? "Pick a workspace in the sidebar, or press ⌘N for a new one — a clean desk in the project for one task and its agents."
            : "Add a project folder. Each task gets its own workspace: agents, terminals and files side by side.")
        body.alignment = .center; body.textColor = .secondaryLabelColor
        let button = ClosureButton(title: hasRepos ? "New Workspace" : "Add Project…") { hasRepos ? Workbench.newWorkspace() : Workbench.addProject() }
        button.bezelStyle = .push; button.keyEquivalent = "\r"; button.controlSize = .large
        let stack = NSStackView(views: [icon, title, body, button])
        stack.orientation = .vertical; stack.spacing = 10; stack.setCustomSpacing(18, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
                                     body.widthAnchor.constraint(equalToConstant: 420)])
    }
    required init?(coder: NSCoder) { fatalError() }
}
