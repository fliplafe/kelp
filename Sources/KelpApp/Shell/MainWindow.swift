import AppKit
import SwiftUI
import Core
import WorkbenchKit

/// The window, as Finder and Xcode are on macOS 26: projects & agents in a sidebar the full height of the window (the
/// traffic lights sit in it), then the window bar (where you are, ⌘P, the inspector toggle) over editor area | inspector.
/// Their first rows (search, tab strips, panel icons) line up as the second row.
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
    /// Settings › Appearance › Auto-hide: that panel stays away the same way, for good.
    private var autoHide = (sidebar: false, inspector: false)
    /// Auto-hide panels the toggle (⌘0 / ⌥⌘0) pinned: they stay in like a normal panel until it's pressed again.
    private var pinned = (sidebar: false, inspector: false)
    private let leftEdge = EdgeTrigger(), rightEdge = EdgeTrigger()
    private let bar = WindowBar()
    /// Fixed in the window bar's corners, whichever panels are open.
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
        for v in [split.view, bar, sidebarToggle, inspectorToggle, leftEdge, rightEdge] { v.translatesAutoresizingMaskIntoConstraints = false; root.view.addSubview(v) }
        leftEdge.isHidden = true; rightEdge.isHidden = true
        leftEdge.onEnter = { [weak self] in self?.peek(sidebar: true) }
        rightEdge.onEnter = { [weak self] in self?.peek(sidebar: false) }
        let lights = w.standardWindowButton(.zoomButton).map { $0.convert($0.bounds, to: nil).maxX } ?? 69
        // The bar lies over the editor area only: the sidebar and the inspector both run the window's full height. With
        // the sidebar away it runs under the traffic lights; with the inspector away, under its toggle.
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: root.view.topAnchor), split.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor), split.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: root.view.topAnchor), bar.heightAnchor.constraint(equalToConstant: WindowBar.height),
            bar.leadingAnchor.constraint(equalTo: editors.view.leadingAnchor), bar.trailingAnchor.constraint(equalTo: editors.view.trailingAnchor),
            // The bar is as tall as the title bar, so the traffic lights and the toggles share a centre line. The sidebar's
            // toggle is in the sidebar's top right corner, or after the traffic lights while the sidebar is away.
            sidebarToggle.leadingAnchor.constraint(greaterThanOrEqualTo: root.view.leadingAnchor, constant: lights + 12),
            { let c = sidebarToggle.trailingAnchor.constraint(equalTo: editors.view.leadingAnchor, constant: -8); c.priority = .init(600); return c }(),
            sidebarToggle.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            // The workspace starts over the editor area; with the sidebar away, after its toggle.
            bar.context.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarToggle.trailingAnchor, constant: 12),
            { let c = bar.context.leadingAnchor.constraint(equalTo: editors.view.leadingAnchor, constant: 12); c.priority = .init(700); return c }(),
            inspectorToggle.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -10),
            inspectorToggle.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor),
            leftEdge.leadingAnchor.constraint(equalTo: root.view.leadingAnchor), leftEdge.widthAnchor.constraint(equalToConstant: 4),
            leftEdge.topAnchor.constraint(equalTo: bar.bottomAnchor), leftEdge.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            rightEdge.trailingAnchor.constraint(equalTo: root.view.trailingAnchor), rightEdge.widthAnchor.constraint(equalToConstant: 4),
            rightEdge.topAnchor.constraint(equalTo: bar.bottomAnchor), rightEdge.bottomAnchor.constraint(equalTo: root.view.bottomAnchor)
        ])
        w.contentViewController = root
        w.title = String(localized: "Kelp"); w.setFrameAutosaveName("main"); w.delegate = self
        if w.frame.origin == .zero { w.center() }
        track { AppModel.shared.worktree(Workbench.shared.workspaceId) } changed: { [weak self] _ in self?.updateTitle() }
        track { SettingsStore.shared.bool("workbench.sidebar.autoHide") == true } changed: { [weak self] in self?.setAutoHide(sidebar: true, $0) }
        track { SettingsStore.shared.bool("workbench.inspector.autoHide") == true } changed: { [weak self] in self?.setAutoHide(sidebar: false, $0) }
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

    /// Narrowed until the editor would have less than 640 pt, the inspector steps aside and comes back once the window has
    /// room again, as Mail's sidebar does (at 1000 pt the two side columns had half the window). Not saved: the inspector
    /// you open or close yourself is (`inspector.collapsed`). The split's own collapse-on-resize only acts on live resizes.
    private var narrowedAt: CGFloat?
    func windowDidResize(_ n: Notification) {
        guard focusMode == nil, !autoHide.inspector, let width = window?.frame.width else { return }
        if let at = narrowedAt {
            if width >= at + 20 { narrowedAt = nil; inspectorItem.isCollapsed = false }   // a little past it, or it flaps
        } else if !inspectorItem.isCollapsed, editors.view.frame.width < 640 {
            narrowedAt = width; inspectorItem.isCollapsed = true
        }
    }

    @objc func toggleInspectorPanel() {
        narrowedAt = nil
        if focusMode != nil { return togglePeek(inspectorItem) }
        if autoHide.inspector { return togglePin(inspectorItem) }
        inspectorItem.animator().isCollapsed.toggle()
        UserDefaults.standard.set(inspectorItem.isCollapsed, forKey: "inspector.collapsed")
    }
    func showInspector(panel: String) {
        if inspectorItem.isCollapsed { if hides(inspectorItem) { peek(sidebar: false) } else { toggleInspectorPanel() } }
        inspector.show(panel: panel)
    }
    @objc func toggleSidebarPanel() {
        if focusMode != nil { togglePeek(sidebarItem) } else if autoHide.sidebar { togglePin(sidebarItem) } else { split.toggleSidebar(nil) }
    }
    var sidebarShown: Bool { !sidebarItem.isCollapsed }
    var inspectorShown: Bool { !inspectorItem.isCollapsed }

    /// Quitting: a peeking panel goes and focus mode's panels come back first, or the split's autosave would start the next launch wrong.
    func leaveFocusMode() {
        peeking?.isCollapsed = true; stopPeek()
        guard let was = focusMode else { return }
        focusMode = nil
        sidebarItem.isCollapsed = was.sidebar; inspectorItem.isCollapsed = was.inspector
        updateEdges(); sidebarToggle.isHidden = false; inspectorToggle.isHidden = false
    }

    @objc func toggleFocusMode() {
        if let was = focusMode {
            focusMode = nil; stopPeek()
            sidebarItem.animator().isCollapsed = was.sidebar; inspectorItem.animator().isCollapsed = was.inspector
        } else {
            stopPeek()
            focusMode = (sidebarItem.isCollapsed || hides(sidebarItem), inspectorItem.isCollapsed || hides(inspectorItem))
            sidebarItem.animator().isCollapsed = true; inspectorItem.animator().isCollapsed = true
        }
        let on = focusMode != nil
        updateEdges()
        sidebarToggle.isHidden = on; inspectorToggle.isHidden = on
    }
    var inFocusMode: Bool { focusMode != nil }

    private func setAutoHide(sidebar: Bool, _ on: Bool) {
        guard on != (sidebar ? autoHide.sidebar : autoHide.inspector) else { return }   // the first, unloaded read keeps the saved layout
        if sidebar { autoHide.sidebar = on; pinned.sidebar = false; focusMode?.sidebar = on } else { autoHide.inspector = on; pinned.inspector = false; focusMode?.inspector = on }
        let item: NSSplitViewItem = sidebar ? sidebarItem : inspectorItem
        if peeking === item { stopPeek() }
        if focusMode == nil {
            item.animator().isCollapsed = on
            if !sidebar { UserDefaults.standard.set(on, forKey: "inspector.collapsed") }
        }
        updateEdges()
    }
    private func hides(_ item: NSSplitViewItem) -> Bool {
        focusMode != nil || (item === sidebarItem ? autoHide.sidebar && !pinned.sidebar : autoHide.inspector && !pinned.inspector)
    }
    private func updateEdges() { leftEdge.isHidden = !hides(sidebarItem); rightEdge.isHidden = !hides(inspectorItem) }

    /// Focus mode and auto-hide: the pointer at an edge brings that panel in; once it leaves the panel for the rest
    /// of the window, the panel goes again. In focus mode ⌘0 / ⌥⌘0 bring it in the same way; with auto-hide they pin it.
    /// (A tracking area on the editor used to end it: while the inspector slid in the editor was still under the
    /// pointer for a frame, so it went straight back out.)
    private var peeking: NSSplitViewItem?
    private var peekMoves: Any?, peekedAt = Date.distantPast
    /// The pointer has been over the panel since it came in (from the edge at once; after ⌘0, once it gets there).
    private var peekReached = false
    private func peek(sidebar: Bool) {
        let item: NSSplitViewItem = sidebar ? sidebarItem : inspectorItem
        guard hides(item), item.isCollapsed else { return }
        endPeek(); peeking = item; peekedAt = Date(); peekReached = false
        editors.hold(from: sidebar ? .minX : .maxX)   // over the editor area, not squeezing it
        item.animator().isCollapsed = false
        window?.acceptsMouseMovedEvents = true
        peekMoves = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in self?.pointerMoved(e); return e }
    }
    private func pointerMoved(_ e: NSEvent) {
        guard let item = peeking, e.window === window, let root = window?.contentView else { return }
        let p = root.convert(e.locationInWindow, from: nil), panel = item.viewController.view
        let edge = item === sidebarItem ? leftEdge : rightEdge
        if panel.convert(panel.bounds, to: root).contains(p) || edge.frame.contains(p) { peekReached = true; return }
        // Not while it slides in: the panel isn't where the pointer is headed yet.
        if peekReached, Date().timeIntervalSince(peekedAt) > 0.4 { endPeek() }
    }
    private func endPeek() {
        if let m = peekMoves { NSEvent.removeMonitor(m); peekMoves = nil }
        guard let p = peeking else { return }
        peeking = nil
        // The editor area fills its place again once the panel is gone (unless another one came in meanwhile).
        NSAnimationContext.runAnimationGroup { _ in p.animator().isCollapsed = true } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.peeking == nil else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()   // the split at its final widths first, or a terminal sees the narrow one
                self.editors.hold(from: nil)
            }
        }
    }
    /// The panels change for good (focus mode, auto-hide switched): no peek, and the editor area fills its place.
    private func stopPeek() {
        if let m = peekMoves { NSEvent.removeMonitor(m); peekMoves = nil }
        peeking = nil; editors.hold(from: nil)
    }
    private func togglePeek(_ item: NSSplitViewItem) { if peeking === item { endPeek() } else { peek(sidebar: item === sidebarItem) } }
    /// Auto-hide: pinned, the panel stays (a peeking one just stops peeking and the editor area makes room);
    /// unpinned, it goes and comes in at the edge again.
    private func togglePin(_ item: NSSplitViewItem) {
        let pin = item === sidebarItem ? !pinned.sidebar : !pinned.inspector
        if item === sidebarItem { pinned.sidebar = pin } else { pinned.inspector = pin }
        if peeking === item { stopPeek() }
        item.animator().isCollapsed = !pin
        updateEdges()
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
    /// The editor area fills this view; while a panel peeks in over it, it keeps its width instead (`hold`).
    private var fill: [NSLayoutConstraint] = [], held: [NSLayoutConstraint] = []

    /// While a panel peeks in (auto-hide, focus mode) the editor area keeps its size and the panel covers its side
    /// (`edge`: where the panel comes from), as a panel over the window would: terminals aren't resized (their agents
    /// redraw everything at a new width) and nothing reflows. Nil lets it fill the view again.
    func hold(from edge: NSRectEdge?) {
        guard let area = current?.view else { return }
        NSLayoutConstraint.deactivate(held); held = []
        guard let edge else { NSLayoutConstraint.activate(fill); return }
        NSLayoutConstraint.deactivate(fill)
        held = [area.widthAnchor.constraint(equalToConstant: area.frame.width),
                edge == .minX ? area.trailingAnchor.constraint(equalTo: view.trailingAnchor) : area.leadingAnchor.constraint(equalTo: view.leadingAnchor)]
        NSLayoutConstraint.activate(held)
        view.clipsToBounds = true
    }

    private var areas: [String: EditorArea] = [:]
    private var recent: [String] = []
    private(set) var current: EditorArea?
    var editedFiles: [SavableTab] { areas.values.flatMap(\.editedFiles) }
    private var welcome: NSView?
    private static let keep = 4

    override func loadView() {
        view = NSView(); showWelcome()
        // Daemon state: workspaces that are gone leave; sessions' tabs come and show their status and context ring.
        track { AppModel.shared.repos } changed: { [weak self] _ in self?.refresh() }
        track { AppModel.shared.worktrees } changed: { [weak self] _ in self?.refresh() }
        track { AppModel.shared.sessions } changed: { [weak self] _ in self?.refresh() }
        track { AppModel.shared.contextShare } changed: { [weak self] _ in self?.refresh() }
    }

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
        // Under the window bar, which lies over this view's top (the split view is the window's full height).
        fill = [area.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), area.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)]
        held = []
        NSLayoutConstraint.activate([area.view.topAnchor.constraint(equalTo: view.topAnchor, constant: WindowBar.height),
                                     area.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)] + fill)
        area.reconcile()
        area.focusSelected()
    }

    /// A tab for a workspace that isn't on screen: into its editor area if it's loaded, else into its saved layout.
    func openInBackground(_ uri: String, workspace id: String) {
        if let a = areas[id] { a.open(uri, focus: false); return }
        var l = WorkspaceLayout.load(id)
        if l.tab(uri: uri) == nil { _ = l.add(uri, to: l.focusedGroup?.id); l.save(id) }
    }

    private func refresh() {
        for (id, a) in areas where AppModel.shared.worktree(id) == nil { a.view.removeFromSuperview(); a.removeFromParent(); areas[id] = nil; recent.removeAll { $0 == id } }
        if let c = current, areas[c.workspaceId] == nil { current = nil; showWelcome() }
        current?.reconcile()   // the others reconcile when shown
        if current == nil { showWelcome() }
    }

    private func showWelcome() {
        let hasRepos = AppModel.shared.repos.contains { !ScratchWindow.isScratch($0) }
        if let w = welcome as? WelcomeView, w.hasRepos == hasRepos { return }
        welcome?.removeFromSuperview()
        let w = WelcomeView(hasRepos: hasRepos)
        w.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(w)
        NSLayoutConstraint.activate([w.topAnchor.constraint(equalTo: view.topAnchor, constant: WindowBar.height), w.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        let button = ClosureButton(title: hasRepos ? String(localized: "New Workspace") : String(localized: "Add Project…")) {
            hasRepos ? Workbench.newWorkspace() : Workbench.addProject()
        }
        button.bezelStyle = .push; button.keyEquivalent = "\r"; button.controlSize = .large
        let stack = NSStackView(views: [icon, title, body, button])
        stack.orientation = .vertical; stack.spacing = 10; stack.setCustomSpacing(18, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
                                     body.widthAnchor.constraint(equalToConstant: 420)])
    }
    required init?(coder: NSCoder) { fatalError() }
}
