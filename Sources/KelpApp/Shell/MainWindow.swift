import AppKit
import SwiftUI
import Core

/// The window: projects & agents | editor area | inspector, without a toolbar: the panes' tab strips sit in the title
/// bar (like Safari's compact tabs), beside the traffic lights and the two panel toggles, so chrome takes one row.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let editors = EditorHost()
    let inspector = InspectorController()
    private let split = NSSplitViewController()
    private var inspectorItem: NSSplitViewItem!
    private var sidebarItem: NSSplitViewItem!
    /// Focus mode (⌃⌘Z): both panels away; they slide in while the pointer is at the window's edge.
    /// Holds the panels' state from before, to put back on leaving.
    private var focusMode: (sidebar: Bool, inspector: Bool)?
    private let leftEdge = EdgeTrigger(), rightEdge = EdgeTrigger()
    /// Fixed in the window's top corners, whichever panels are open.
    private let sidebarToggle = NSButton.titlebar("sidebar.left", String(localized: "Sidebar"), tip: String(localized: "Show or hide the sidebar (⌘0)"))
    private let inspectorToggle = NSButton.titlebar("sidebar.trailing", String(localized: "Inspector"), tip: String(localized: "Show or hide the inspector (⌥⌘0)"))

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: w)
        // The title stays set: the Window menu, Mission Control and VoiceOver read it.
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.titlebarSeparatorStyle = .none
        let sb = NSSplitViewItem(sidebarWithViewController: SidebarController())
        sb.minimumThickness = 220; sb.maximumThickness = 400; sb.canCollapse = true
        let content = NSSplitViewItem(viewController: editors)
        content.minimumThickness = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 250; inspectorItem.maximumThickness = 520; inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = UserDefaults.standard.bool(forKey: "inspector.collapsed")
        sidebarItem = sb
        [sb, content, inspectorItem].forEach(split.addSplitViewItem)
        split.splitView.autosaveName = "main.split"
        let root = NSViewController(); root.view = NSView(); root.addChild(split)
        sidebarToggle.target = self; sidebarToggle.action = #selector(toggleSidebarPanel)
        inspectorToggle.target = self; inspectorToggle.action = #selector(toggleInspectorPanel)
        for v in [split.view, sidebarToggle, inspectorToggle, leftEdge, rightEdge] { v.translatesAutoresizingMaskIntoConstraints = false; root.view.addSubview(v) }
        leftEdge.isHidden = true; rightEdge.isHidden = true
        leftEdge.onEnter = { [weak self] in self?.peek(sidebar: true) }
        rightEdge.onEnter = { [weak self] in self?.peek(sidebar: false) }
        editors.onPointerEntered = { [weak self] in self?.endPeek() }
        let lights = w.standardWindowButton(.zoomButton).map { $0.convert($0.bounds, to: nil).maxX } ?? 69
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: root.view.topAnchor), split.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor), split.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            // The title bar is as tall as a tab strip, so the traffic lights, the toggles and the tabs share a centre line.
            sidebarToggle.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: lights + 12),
            sidebarToggle.centerYAnchor.constraint(equalTo: root.view.topAnchor, constant: TabStrip.height / 2),
            inspectorToggle.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -10),
            inspectorToggle.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor),
            leftEdge.leadingAnchor.constraint(equalTo: root.view.leadingAnchor), leftEdge.widthAnchor.constraint(equalToConstant: 4),
            leftEdge.topAnchor.constraint(equalTo: root.view.topAnchor, constant: TabStrip.height), leftEdge.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            rightEdge.trailingAnchor.constraint(equalTo: root.view.trailingAnchor), rightEdge.widthAnchor.constraint(equalToConstant: 4),
            rightEdge.topAnchor.constraint(equalTo: root.view.topAnchor, constant: TabStrip.height), rightEdge.bottomAnchor.constraint(equalTo: root.view.bottomAnchor)
        ])
        w.contentViewController = root
        w.title = String(localized: "Kelp"); w.setFrameAutosaveName("main"); w.delegate = self
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
        window?.title = AppModel.shared.worktree(Workbench.shared.workspaceId)?.displayName ?? String(localized: "Kelp")
        editors.current?.showEdited()   // a workspace with unsaved files keeps saying so after a switch
    }

    /// What a tab strip in the title bar keeps clear of (window coordinates): the traffic lights with the sidebar
    /// toggle when the sidebar is closed, the inspector toggle when the inspector is.
    var titlebarObstacles: [NSRect] {
        let s = sidebarToggle.convert(sidebarToggle.bounds, to: nil)
        return [NSRect(x: 0, y: s.minY, width: s.maxX + 6, height: s.height), inspectorToggle.convert(inspectorToggle.bounds, to: nil).insetBy(dx: -6, dy: 0)]
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
    var sidebarShown: Bool { !sidebarItem.isCollapsed }
    var inspectorShown: Bool { !inspectorItem.isCollapsed }

    /// Quitting in focus mode: the panels come back first, or the split's autosave would start the next launch without them.
    func leaveFocusMode() {
        guard let was = focusMode else { return }
        focusMode = nil; peeking = nil
        sidebarItem.isCollapsed = was.sidebar; inspectorItem.isCollapsed = was.inspector
        leftEdge.isHidden = true; rightEdge.isHidden = true; sidebarToggle.isHidden = false; inspectorToggle.isHidden = false
    }

    @objc func toggleFocusMode() {
        if let was = focusMode {
            focusMode = nil; peeking = nil
            sidebarItem.animator().isCollapsed = was.sidebar; inspectorItem.animator().isCollapsed = was.inspector
        } else {
            focusMode = (sidebarItem.isCollapsed, inspectorItem.isCollapsed)
            sidebarItem.animator().isCollapsed = true; inspectorItem.animator().isCollapsed = true
        }
        let on = focusMode != nil
        leftEdge.isHidden = !on; rightEdge.isHidden = !on
        sidebarToggle.isHidden = on; inspectorToggle.isHidden = on
    }
    var inFocusMode: Bool { focusMode != nil }

    /// Focus mode: the pointer at an edge brings that panel in; back over the editor, it goes again.
    private var peeking: NSSplitViewItem?
    private func peek(sidebar: Bool) {
        guard focusMode != nil else { return }
        let item: NSSplitViewItem = sidebar ? sidebarItem : inspectorItem
        guard item.isCollapsed else { return }
        endPeek(); peeking = item; item.animator().isCollapsed = false
    }
    private func endPeek() {
        guard focusMode != nil, let p = peeking else { return }
        peeking = nil; p.animator().isCollapsed = true
    }

    /// Closing the window quits (the daemon keeps agents running) — through the unsaved-files question; Cancel keeps it.
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
}

extension NSButton {
    /// An icon button for the title bar, outlined on hover like the toolbar buttons it stands in for.
    static func titlebar(_ symbol: String, _ label: String, tip: String) -> NSButton {
        let b = NSButton(image: .symbol(symbol, label), target: nil, action: nil)
        b.bezelStyle = .recessed; b.showsBorderOnlyWhileMouseInside = true; b.toolTip = tip
        b.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        return b
    }
}

/// A strip at the window's edge that reports the pointer arriving (focus mode's way back to the panels).
@MainActor
final class EdgeTrigger: NSView {
    var onEnter: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onEnter?() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }   // clicks go to whatever is under it
}

/// Holds one editor area per recently used workspace, so switching back is instant (terminals stay attached).
@MainActor
final class EditorHost: NSViewController {
    var onPointerEntered: (() -> Void)?
    override func viewDidLayout() {
        super.viewDidLayout()
        view.trackingAreas.forEach(view.removeTrackingArea)
        view.addTrackingArea(NSTrackingArea(rect: view.bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onPointerEntered?() }
    private var areas: [String: EditorArea] = [:]
    private var recent: [String] = []
    private(set) var current: EditorArea?
    var editedFiles: [SavableTab] { areas.values.flatMap(\.editedFiles) }
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
        // Up into the title bar: the top panes' tab strips are the window's title bar.
        NSLayoutConstraint.activate([area.view.topAnchor.constraint(equalTo: view.topAnchor),
                                     area.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     area.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), area.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        area.reconcile()
        area.focusSelected()
    }

    /// A tab for a workspace that isn't on screen: into its editor area if it's loaded, else into its saved layout.
    func openInBackground(_ uri: String, workspace id: String) {
        if let a = areas[id] { a.open(uri); return }
        var l = WorkspaceLayout.load(id)
        if l.tab(uri: uri) == nil { _ = l.add(uri, to: l.focusedGroup?.id); l.save(id) }
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
        let hasRepos = AppModel.shared.repos.contains { !ScratchWindow.isScratch($0) }
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
        let title = NSTextField(labelWithString: hasRepos ? String(localized: "Select a workspace") : String(localized: "Welcome to Kelp"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: hasRepos
            ? String(localized: "Pick a workspace in the sidebar, or press ⌘N for a new one — a clean desk in the project for one task and its agents.")
            : String(localized: "Add a project folder. Each task gets its own workspace: agents, terminals and files side by side."))
        body.alignment = .center; body.textColor = .secondaryLabelColor
        let button = ClosureButton(title: hasRepos ? String(localized: "New Workspace") : String(localized: "Add Project…")) { hasRepos ? Workbench.newWorkspace() : Workbench.addProject() }
        button.bezelStyle = .push; button.keyEquivalent = "\r"; button.controlSize = .large
        let stack = NSStackView(views: [icon, title, body, button])
        stack.orientation = .vertical; stack.spacing = 10; stack.setCustomSpacing(18, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
                                     body.widthAnchor.constraint(equalToConstant: 420)])
    }
    required init?(coder: NSCoder) { fatalError() }
}
