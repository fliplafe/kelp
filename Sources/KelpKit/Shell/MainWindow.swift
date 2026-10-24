import AppKit
import SwiftUI
import Core
import WorkbenchKit

/// The window, as Arc and Safari are: one surface — projects & agents in the sidebar (the traffic lights sit in it), the
/// window bar (where you are, ⌘P), the inspector — wrapped round the editor area, a card with rounded corners. The
/// panels' first rows (search, panel icons) line up with the card's tab strips. An auto-hidden panel (and focus mode's)
/// comes in over the card instead, floating clear of the window's edges.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// The app this window shows: handed to its panels and editor areas.
    let app: AppModel
    let editors: EditorHost
    let inspector: InspectorController
    private let sidebar: SidebarController
    private let split = ShellSplit()
    private let inspectorItem: NSSplitViewItem
    private let sidebarItem: NSSplitViewItem
    /// Focus mode (⌃⌘Z): both panels away; they slide in while the pointer is at the window's edge.
    /// Holds the panels' state from before, to put back on leaving.
    private var focusMode: (sidebar: Bool, inspector: Bool)?
    /// Settings › Appearance › Auto-hide: that panel stays away the same way, for good.
    private var autoHide = (sidebar: false, inspector: false)
    /// Auto-hide panels the toggle (⌘0 / ⌥⌘0) pinned: they stay in like a normal panel until it's pressed again.
    private var pinned = (sidebar: false, inspector: false)
    private let leftEdge = EdgeTrigger(), rightEdge = EdgeTrigger()
    /// Where a hiding panel is while it's away, and comes in from.
    private let leftFloat = Floater(width: 260), rightFloat = Floater(width: 300)
    private lazy var bar = WindowBar(app: app)
    /// Fixed in the window bar's corners, whichever panels are open.
    private let sidebarToggle = NSButton.titlebar("sidebar.left", String(localized: "Sidebar"), tip: String(localized: "Show or hide the sidebar (⌘0)"))
    private let inspectorToggle = NSButton.titlebar("sidebar.trailing", String(localized: "Inspector"),
                                                    tip: String(localized: "Show or hide the inspector (⌥⌘0)"))

    init(app: AppModel) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        self.app = app
        editors = EditorHost(app: app)
        sidebar = SidebarController(app: app); inspector = InspectorController(app: app)
        sidebarItem = Self.column(sidebar); inspectorItem = Self.column(inspector)
        super.init(window: w)
        app.workbench.window = self   // what acts on the window reaches it there
        // The title stays set: the Window menu, Mission Control and VoiceOver read it.
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.titlebarSeparatorStyle = .none
        sidebarItem.minimumThickness = 220; sidebarItem.maximumThickness = 400
        let content = NSSplitViewItem(viewController: editors)
        content.minimumThickness = 420
        inspectorItem.minimumThickness = 250; inspectorItem.maximumThickness = 520
        inspectorItem.isCollapsed = UserDefaults.standard.bool(forKey: "inspector.collapsed")
        [sidebarItem, content, inspectorItem].forEach(split.addSplitViewItem)
        split.splitView.autosaveName = "main.split"
        let root = NSViewController(); root.view = DropRoot(app: app); root.addChild(split)
        sidebarToggle.target = self; sidebarToggle.action = #selector(toggleSidebarPanel)
        inspectorToggle.target = self; inspectorToggle.action = #selector(toggleInspectorPanel)
        root.view.pin(split.view)
        for v in [bar, leftFloat, rightFloat, sidebarToggle, inspectorToggle, leftEdge, rightEdge] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.view.addSubview(v)
        }
        leftFloat.attach(leading: true); rightFloat.attach(leading: false)
        leftEdge.isHidden = true; rightEdge.isHidden = true
        leftEdge.onEnter = { [weak self] in self?.peek(sidebar: true) }
        rightEdge.onEnter = { [weak self] in self?.peek(sidebar: false) }
        let lights = w.standardWindowButton(.zoomButton).map { $0.convert($0.bounds, to: nil).maxX } ?? 69
        // The bar lies over the editor area only: the sidebar and the inspector both run the window's full height. With
        // the sidebar away it runs under the traffic lights; with the inspector away, under its toggle.
        NSLayoutConstraint.activate([
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
        track { app.worktree(app.workbench.workspaceId) } changed: { [weak self] _ in self?.updateTitle() }
        track { app.settings.bool("workbench.sidebar.autoHide") == true } changed: { [weak self] in
            self?.setAutoHide(sidebar: true, $0)
            self?.sidebarToggle.menu = self?.autoHideMenu(String(localized: "Auto-Hide Sidebar"), "workbench.sidebar.autoHide", $0)
        }
        track { app.settings.bool("workbench.inspector.autoHide") == true } changed: { [weak self] in
            self?.setAutoHide(sidebar: false, $0)
            self?.inspectorToggle.menu = self?.autoHideMenu(String(localized: "Auto-Hide Inspector"), "workbench.inspector.autoHide", $0)
        }
    }
    /// A panel's column. It holds the panel while it's docked; while the panel hides (auto-hide, focus mode) the panel is
    /// in its floater and the column stays collapsed.
    private static func column(_ panel: NSViewController) -> NSSplitViewItem {
        let slot = NSViewController(); slot.view = NSView(); slot.addChild(panel); slot.view.pin(panel.view)
        let item = NSSplitViewItem(viewController: slot)
        item.canCollapse = true; item.holdingPriority = .init(260)   // a resized window widens the editor area, not the panels
        return item
    }
    /// The toggles' right-click menu: the panel's auto-hide, as in Settings › Appearance.
    private func autoHideMenu(_ title: String, _ key: String, _ on: Bool) -> NSMenu {
        let m = NSMenu(), app = app
        m.add(title) { app.settings.set(key, .bool(!on)) }.state = on ? .on : .off
        return m
    }
    required init?(coder: NSCoder) { fatalError() }

    func showWorkspace(_ id: String?) {
        editors.show(id)
        updateTitle()
        app.publishUIState()
    }

    private func updateTitle() {
        window?.title = app.worktree(app.workbench.workspaceId)?.displayName ?? String(localized: "Kelp")
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
        if inspectorItem.isCollapsed, peeking !== inspectorItem { if hides(inspectorItem) { peek(sidebar: false) } else { toggleInspectorPanel() } }
        inspector.show(panel: panel)
    }
    @objc func toggleSidebarPanel() {
        if focusMode != nil { togglePeek(sidebarItem) } else if autoHide.sidebar { togglePin(sidebarItem) } else { sidebarItem.animator().isCollapsed.toggle() }
    }
    var sidebarShown: Bool { !sidebarItem.isCollapsed || peeking === sidebarItem }
    var inspectorShown: Bool { !inspectorItem.isCollapsed || peeking === inspectorItem }

    /// Quitting: focus mode's panels come back first, or the split's autosave would start the next launch wrong.
    func leaveFocusMode() {
        stopPeek()
        guard let was = focusMode else { return }
        focusMode = nil
        place()
        sidebarItem.isCollapsed = was.sidebar; inspectorItem.isCollapsed = was.inspector
        sidebarToggle.isHidden = false; inspectorToggle.isHidden = false
    }

    @objc func toggleFocusMode() {
        stopPeek()
        if let was = focusMode {
            focusMode = nil; place()
            sidebarItem.animator().isCollapsed = was.sidebar; inspectorItem.animator().isCollapsed = was.inspector
        } else {
            focusMode = (sidebarItem.isCollapsed || hides(sidebarItem), inspectorItem.isCollapsed || hides(inspectorItem))
            place()   // before the columns close: the floaters take their widths
            sidebarItem.animator().isCollapsed = true; inspectorItem.animator().isCollapsed = true
        }
        let on = focusMode != nil
        sidebarToggle.isHidden = on; inspectorToggle.isHidden = on
    }
    var inFocusMode: Bool { focusMode != nil }

    private func setAutoHide(sidebar: Bool, _ on: Bool) {
        guard on != (sidebar ? autoHide.sidebar : autoHide.inspector) else { return }   // the first, unloaded read keeps the saved layout
        if sidebar {
            autoHide.sidebar = on
            pinned.sidebar = false
            focusMode?.sidebar = on
        } else {
            autoHide.inspector = on
            pinned.inspector = false
            focusMode?.inspector = on
        }
        let item: NSSplitViewItem = sidebar ? sidebarItem : inspectorItem
        if peeking === item { stopPeek() }
        place()
        if focusMode == nil {
            item.animator().isCollapsed = on
            if !sidebar { UserDefaults.standard.set(on, forKey: "inspector.collapsed") }
        }
    }
    private func hides(_ item: NSSplitViewItem) -> Bool {
        focusMode != nil || (item === sidebarItem ? autoHide.sidebar && !pinned.sidebar : autoHide.inspector && !pinned.inspector)
    }
    private func floater(_ item: NSSplitViewItem) -> Floater { item === sidebarItem ? leftFloat : rightFloat }

    /// Each panel where it belongs now: in its column, or in its floater while it hides. A panel leaving its open column
    /// for the floater keeps its width there.
    private func place() {
        for (item, panel, edge) in [(sidebarItem, sidebar.view, leftEdge), (inspectorItem, inspector.view, rightEdge)] {
            let hide = hides(item), f = floater(item), column = item.viewController.view
            edge.isHidden = !hide
            if hide, panel.superview !== f.box {
                if !item.isCollapsed, column.frame.width >= item.minimumThickness { f.width = column.frame.width }
                f.box.pin(panel)
            } else if !hide, panel.superview !== column {
                column.pin(panel)
            }
        }
    }

    /// Focus mode and auto-hide: the pointer at an edge brings that panel in over the editor area (which keeps its size:
    /// terminals aren't resized, nothing reflows); once the pointer leaves the panel for the rest of the window, the
    /// panel goes again. In focus mode ⌘0 / ⌥⌘0 bring it in the same way; with auto-hide they pin it.
    private var peeking: NSSplitViewItem?
    private var peekMoves: Any?, peekedAt = Date.distantPast
    /// The pointer has been over the panel since it came in (from the edge at once; after ⌘0, once it gets there).
    private var peekReached = false
    private func peek(sidebar: Bool) {
        let item: NSSplitViewItem = sidebar ? sidebarItem : inspectorItem
        guard hides(item), peeking !== item else { return }
        endPeek(); peeking = item; peekedAt = Date(); peekReached = false
        floater(item).slide(in: true)
        window?.acceptsMouseMovedEvents = true
        peekMoves = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in self?.pointerMoved(e); return e }
    }
    private func pointerMoved(_ e: NSEvent) {
        guard let item = peeking, e.window === window, let root = window?.contentView else { return }
        let p = root.convert(e.locationInWindow, from: nil)
        let edge = item === sidebarItem ? leftEdge : rightEdge
        if floater(item).frame.contains(p) || edge.frame.contains(p) { peekReached = true; return }
        // Not while it slides in: the panel isn't where the pointer is headed yet.
        if peekReached, Date().timeIntervalSince(peekedAt) > 0.4 { endPeek() }
    }
    private func endPeek(animated: Bool = true) {
        if let m = peekMoves { NSEvent.removeMonitor(m); peekMoves = nil }
        guard let p = peeking else { return }
        peeking = nil
        floater(p).slide(in: false, animated: animated)
    }
    /// The panels change for good (focus mode, auto-hide switched, pinned): the peeking one goes at once.
    private func stopPeek() { endPeek(animated: false) }
    private func togglePeek(_ item: NSSplitViewItem) { if peeking === item { endPeek() } else { peek(sidebar: item === sidebarItem) } }
    /// Auto-hide: pinned, the panel stays in its column (a peeking one moves there); unpinned, it goes and comes in at
    /// the edge again.
    private func togglePin(_ item: NSSplitViewItem) {
        let pin = item === sidebarItem ? !pinned.sidebar : !pinned.inspector
        if item === sidebarItem { pinned.sidebar = pin } else { pinned.inspector = pin }
        if peeking === item { stopPeek() }
        place()
        item.animator().isCollapsed = !pin
    }

    /// Closing the window quits (the daemon keeps agents running) — through the unsaved-files question; Cancel keeps it.
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
}

/// The window's split: its dividers aren't drawn (the panels and the gap round the card are one surface), and each can
/// be dragged across that gap too, not only at the panel's edge.
@MainActor
private final class ShellSplit: NSSplitViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        let v = Seamless(); v.isVertical = true; v.dividerStyle = .thin
        splitView = v
    }
    required init?(coder: NSCoder) { fatalError() }
    override func splitView(_ v: NSSplitView, effectiveRect proposed: NSRect, forDrawnRect drawn: NSRect, ofDividerAt i: Int) -> NSRect {
        var r = super.splitView(v, effectiveRect: proposed, forDrawnRect: drawn, ofDividerAt: i)
        r.size.width += Card.gap; if i > 0 { r.origin.x -= Card.gap }   // into the gap, which is on the editor area's side
        return r
    }
    private final class Seamless: NSSplitView { override var dividerColor: NSColor { .clear } }
}

/// A hiding panel's place (auto-hide, focus mode): it holds the panel while it's away and, at the window's edge, brings
/// it in over the editor area, clear of the window's edges, with rounded corners and a shadow, as Arc's sidebar does.
@MainActor
final class Floater: NSView {
    private static let inset: CGFloat = 6, radius: CGFloat = 12
    /// The panel's background, the same material the window's surface is.
    let box = NSVisualEffectView()
    private var edge: NSLayoutConstraint?, widthC: NSLayoutConstraint?
    private var shown = false
    var width: CGFloat { didSet { widthC?.constant = width } }

    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        isHidden = true; wantsLayer = true
        box.material = .sidebar; box.blendingMode = .behindWindow; box.state = .followsWindowActiveState
        box.wantsLayer = true; box.layer?.cornerRadius = Self.radius; box.layer?.cornerCurve = .continuous; box.layer?.masksToBounds = true
        box.layer?.borderWidth = 1
        pin(box)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Against the window's leading or trailing edge, its full height; out of sight until it slides in.
    func attach(leading: Bool) {
        guard let s = superview else { return }
        let e = leading ? leadingAnchor.constraint(equalTo: s.leadingAnchor) : s.trailingAnchor.constraint(equalTo: trailingAnchor)
        let w = widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([e, w, topAnchor.constraint(equalTo: s.topAnchor, constant: Self.inset),
                                     bottomAnchor.constraint(equalTo: s.bottomAnchor, constant: -Self.inset)])
        edge = e; widthC = w
    }

    func slide(in on: Bool, animated: Bool = true) {
        guard let edge, on != shown else { return }
        shown = on
        let away = -width - 2 * Self.inset - 20   // the shadow out of sight too
        if on, isHidden { edge.constant = away; isHidden = false; superview?.layoutSubtreeIfNeeded() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: on ? .easeOut : .easeIn)
            edge.animator().constant = on ? Self.inset : away
        } completionHandler: { [weak self] in   // on main
            MainActor.assumeIsolated { if let self, !self.shown { self.isHidden = true } }
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.shadowColor = NSColor.shadowColor.cgColor; layer?.shadowOpacity = 0.3; layer?.shadowRadius = 14; layer?.shadowOffset = .zero
    }
    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }
}

/// The editor area's card: rounded, a hairline round it, in from the panels and the window's edges, so the panels and
/// the window bar read as one surface round it.
@MainActor
final class Card: NSView {
    static let gap: CGFloat = 6
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 10; layer?.cornerCurve = .continuous; layer?.masksToBounds = true; layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; layer?.borderColor = NSColor.separatorColor.cgColor }
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

/// The window's surface, in the sidebar's material: the panels and the gap round the editor area are this.
/// Files and folders dropped where nothing else takes them (the empty workspace, the window bar, the inspector): as if
/// dropped on the Dock icon.
@MainActor
private final class DropRoot: NSVisualEffectView {
    private let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        material = .sidebar; blendingMode = .behindWindow; state = .followsWindowActiveState
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { Workbench.files(s).isEmpty ? [] : .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let files = Workbench.files(s)
        app.workbench.open(files: files); return !files.isEmpty
    }
}

/// Holds one editor area per recently used workspace, so switching back is instant (terminals stay attached).
@MainActor
final class EditorHost: NSViewController {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    /// The editor area (or the welcome) is in this card, under the window bar, which lies over this view's top.
    private let card = Card()
    private var areas: [String: EditorArea] = [:]
    private var recent: [String] = []
    private(set) var current: EditorArea?
    var editedFiles: [SavableTab] { areas.values.flatMap(\.editedFiles) }
    func editedFiles(in ids: [String]) -> [SavableTab] { ids.compactMap { areas[$0] }.flatMap(\.editedFiles) }
    private var welcome: NSView?
    private static let keep = 4

    override func loadView() {
        let app = self.app
        view = NSView()
        view.pin(card, inset: NSEdgeInsets(top: WindowBar.height, left: Card.gap, bottom: Card.gap, right: Card.gap))
        showWelcome()
        // Daemon state: workspaces that are gone leave; sessions' tabs come and show their status and context ring.
        track { app.repos } changed: { [weak self] _ in self?.refresh() }
        track { app.worktrees } changed: { [weak self] _ in self?.refresh() }
        track { app.sessions } changed: { [weak self] _ in self?.refresh() }
        track { app.contextShare } changed: { [weak self] _ in self?.refresh() }
    }

    func show(_ id: String?) {
        if let c = current, c.workspaceId == id { return }
        current?.view.removeFromSuperview()
        guard let id, app.worktree(id) != nil else { current = nil; showWelcome(); return }
        welcome?.removeFromSuperview(); welcome = nil
        let area = areas[id] ?? EditorArea(app: app, workspaceId: id)
        if areas[id] == nil { areas[id] = area; addChild(area) }
        recent.removeAll { $0 == id }; recent.insert(id, at: 0)
        // Their terminals detach.
        let gone: [String]
        (recent, gone) = Self.evicting(recent, keep: Self.keep) { self.areas[$0]?.editedFiles.isEmpty == false }
        for old in gone { areas[old]?.removeFromParent(); areas[old] = nil }
        current = area
        card.pin(area.view)
        area.reconcile()
        area.focusSelected()
    }

    /// The areas past the newest `keep` go, except those with unsaved files: they stay listed, and go on a later switch
    /// once saved (dropped from the list, one would stay loaded, and its terminal attached, until shown again).
    static func evicting(_ recent: [String], keep: Int, edited: (String) -> Bool) -> (recent: [String], gone: [String]) {
        let gone = recent.dropFirst(keep).filter { !edited($0) }
        return (recent.filter { !gone.contains($0) }, gone)
    }

    /// A tab for a workspace that isn't on screen: into its editor area if it's loaded, else into its saved layout.
    func openInBackground(_ uri: String, workspace id: String) {
        if let a = areas[id] { a.open(uri, focus: false); return }
        var l = WorkspaceLayout.load(id, from: app.uiState)
        if l.tab(uri: uri) == nil { _ = l.add(uri, to: l.focusedGroup?.id); l.save(id, to: app.uiState) }
    }

    /// A restarted session into its old tab in a workspace that isn't on screen, the same two ways.
    func replaceInBackground(_ old: String, with new: String, workspace id: String) {
        if let a = areas[id] { a.replace(old, with: new, focus: false); return }
        var l = WorkspaceLayout.load(id, from: app.uiState)
        if l.replace(old, with: new) == nil, l.tab(uri: new) == nil { l.add(new, to: l.focusedGroup?.id) }
        l.save(id, to: app.uiState)
    }

    private func refresh() {
        for (id, a) in areas where app.worktree(id) == nil {
            a.view.removeFromSuperview(); areas[id] = nil; recent.removeAll { $0 == id }
            // Closed from elsewhere (the CLI, an agent): unsaved files still get their question, only without Cancel.
            let edited = a.editedFiles
            guard !edited.isEmpty else { a.removeFromParent(); continue }
            Task {
                let answer = await runSheet(UnsavedChanges.alert(edited, quitting: false, canCancel: false))
                if await UnsavedChanges.settle(edited, answer, canCancel: false) { _ = await UnsavedChanges.written(edited) }
                a.removeFromParent()
            }
        }
        if let c = current, areas[c.workspaceId] == nil { current = nil; showWelcome() }
        current?.reconcile()   // the others reconcile when shown
        if current == nil { showWelcome() }
    }

    private func showWelcome() {
        let hasRepos = app.repos.contains { !ScratchWindow.isScratch($0) }
        if let w = welcome as? WelcomeView, w.hasRepos == hasRepos { return }
        welcome?.removeFromSuperview()
        let w = WelcomeView(hasRepos: hasRepos, app: app)
        card.pin(w)
        welcome = w
    }
}

/// No workspace selected: first-run guidance.
@MainActor
final class WelcomeView: NSView {
    let hasRepos: Bool
    init(hasRepos: Bool, app: AppModel) {
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
        let button = ClosureButton(title: hasRepos ? String(localized: "New Workspace") : String(localized: "Add Project…")) { [app] in
            hasRepos ? app.workbench.newWorkspace() : app.workbench.addProject()
        }
        button.bezelStyle = .push; button.keyEquivalent = "\r"; button.controlSize = .large
        let stack = NSStackView(views: [icon, title, body, button])
        stack.orientation = .vertical; stack.spacing = 10; stack.setCustomSpacing(18, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
                                     body.widthAnchor.constraint(equalToConstant: 420)])
    }
    required init?(coder: NSCoder) { fatalError() }
}
