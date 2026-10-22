import AppKit
import SwiftUI
import Core

/// Right side: a row of panel icons (from extensions) over the selected panel — a scope bar like Mail's and Finder's:
/// plain icons, the selected one on a soft background. The row is the inspector's part of the window's second row,
/// or a bar under the panel. Icons are dragged into order; a right-click on the row hides them and moves the row.
@MainActor
final class InspectorController: NSViewController {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    private let selector = CapsuleStack()
    private var buttons: [NSButton] = []
    private var counts: [CountBadge] = []   // one per button
    private let host = NSView()   // clips: see showSelected
    private var panels: [PanelSpec] = []
    private var made: [String: NSViewController] = [:]
    /// Settings › Appearance › Inspector icons: one of these holds the row (left, centered, right).
    private var align: [String: NSLayoutConstraint] = [:]
    /// Settings › Appearance › Inspector icons position: the row level with the tabs, or a bar under the panel.
    private var top: [NSLayoutConstraint] = [], bottom: [NSLayoutConstraint] = []
    private let rowSep = NSBox()   // over the bar at the bottom
    /// The panel's name in the inspector's top band, level with the traffic lights: the icons alone don't say where you are.
    private let panelTitle = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: String(localized: "No panels — enable extensions in Settings."))
    private static let orderKey = "workbench.inspector.panelOrder", hiddenKey = "workbench.inspector.hiddenPanels"

    override func loadView() {
        let v = InspectorView()
        v.rowMenu = { [weak self] in self?.rowMenu($0) }
        // A segmented capsule, like the system's scope bars on macOS 26: the shown panel's icon on a soft fill.
        selector.spacing = 2; selector.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        empty.textColor = .secondaryLabelColor; empty.alignment = .center
        panelTitle.font = .ui(13, weight: .semibold); panelTitle.lineBreakMode = .byTruncatingTail
        panelTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.clipsToBounds = true
        let sep = NSBox(); sep.boxType = .separator; rowSep.boxType = .separator
        for x in [selector, sep, rowSep, panelTitle, host, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        // Like the sidebar, the inspector runs the window's full height: the top band (as tall as the title bar) holds the
        // panel's name and, in the corner, the window's inspector toggle; its rows start under it.
        let under = NSLayoutGuide(); v.addLayoutGuide(under)
        under.topAnchor.constraint(equalTo: v.topAnchor, constant: WindowBar.height).isActive = true
        align = ["left": selector.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
                 "center": selector.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                 "right": selector.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8)]
        align.values.forEach { $0.priority = .defaultHigh }
        // Level with the tabs, the full height of their strip; or as tall, under the panel.
        top = [selector.centerYAnchor.constraint(equalTo: under.topAnchor, constant: TabStrip.height / 2), host.bottomAnchor.constraint(equalTo: v.bottomAnchor),
               host.topAnchor.constraint(equalTo: sep.bottomAnchor)]
        bottom = [selector.centerYAnchor.constraint(equalTo: v.bottomAnchor, constant: -TabStrip.height / 2),
                  rowSep.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -TabStrip.height),
                  host.bottomAnchor.constraint(equalTo: rowSep.topAnchor), host.topAnchor.constraint(equalTo: under.topAnchor)]
        NSLayoutConstraint.activate([
            selector.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 8), selector.heightAnchor.constraint(equalToConstant: 28),
            panelTitle.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14), panelTitle.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -48),
            panelTitle.centerYAnchor.constraint(equalTo: v.topAnchor, constant: WindowBar.height / 2),
            selector.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -8),
            sep.bottomAnchor.constraint(equalTo: under.topAnchor, constant: TabStrip.height),
            sep.leadingAnchor.constraint(equalTo: v.leadingAnchor), sep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            rowSep.leadingAnchor.constraint(equalTo: v.leadingAnchor), rowSep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            host.leadingAnchor.constraint(equalTo: v.leadingAnchor), host.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        v.onShow = { [weak self] in self?.showSelected() }
        view = v
        // Panels are built with the text size of the moment: rebuilt when it changes (first, while none are built).
        track(owner: self) { [app] in app.settings.string("workbench.textSize") } changed: { [weak self] _ in
            guard let self else { return }
            for (_, vc) in made { vc.view.removeFromSuperview(); vc.removeFromParent() }
            made = [:]; showSelected()
        }
        track(owner: self) { [app] in app.extensions.revision } changed: { [weak self] _ in self?.forgetFolderPanels(); self?.rebuild() }
        track(owner: self) { [app] in [app.settings.value(Self.orderKey), app.settings.value(Self.hiddenKey)] } changed: { [weak self] _ in self?.rebuild() }
        track(owner: self) { [app] in app.settings.string("workbench.inspectorIconsPosition") == "bottom" } changed: { [weak self] in
            guard let self else { return }
            NSLayoutConstraint.deactivate($0 ? self.top : self.bottom); NSLayoutConstraint.activate($0 ? self.bottom : self.top)
            self.rowSep.isHidden = !$0; sep.isHidden = $0
        }
        track(owner: self) { [app] in app.workbench.inspectorPanel } changed: { [weak self] _ in self?.showSelected() }
        track(owner: self) { [app] in app.extensions.all.panels.map { $0.badge?() ?? 0 } } changed: { [weak self] _ in self?.showCounts() }
        track(owner: self) { [app] in app.settings.string("workbench.inspectorIcons") } changed: { [weak self] in
            guard let self else { return }
            let want = self.align[$0 ?? ""] == nil ? "center" : $0 ?? ""
            for (k, c) in self.align { c.isActive = k == want }
        }
    }

    private func rebuild() {
        // In the order the row was dragged into; panels it doesn't name yet follow in the registry's order.
        let order = ids(Self.orderKey), hidden = Set(ids(Self.hiddenKey))
        func rank(_ e: (offset: Int, element: PanelSpec)) -> (Int, Int) { (order.firstIndex(of: e.element.id) ?? .max, e.offset) }
        panels = app.extensions.all.panels.enumerated().sorted { rank($0) < rank($1) }.map(\.element)
        let ids = Set(panels.map(\.id))
        for k in made.keys where !ids.contains(k) { made[k]?.view.removeFromSuperview(); made[k]?.removeFromParent(); made[k] = nil }
        buttons.forEach { $0.removeFromSuperview() }
        counts = []
        buttons = panels.enumerated().map { i, p in
            let b = PanelIcon(p.icon, loc(p.title))
            b.target = self; b.action = #selector(selected(_:)); b.tag = i; b.isHidden = hidden.contains(p.id)
            b.moved = { [weak self, weak b] x in if let self, let b { self.move(b, to: x) } }
            b.dropped = { [weak self] in self?.saveOrder() }
            b.contextMenu = { [weak self] in self?.rowMenu($0) }
            b.widthAnchor.constraint(equalToConstant: 38).isActive = true; b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let n = CountBadge(); n.translatesAutoresizingMaskIntoConstraints = false; b.addSubview(n)   // on the icon's top-right corner
            NSLayoutConstraint.activate([n.leadingAnchor.constraint(equalTo: b.centerXAnchor, constant: 2),
                                         n.centerYAnchor.constraint(equalTo: b.centerYAnchor, constant: -6)])
            counts.append(n)
            selector.addArrangedSubview(b)
            return b
        }
        selector.isHidden = panels.isEmpty; empty.isHidden = !panels.isEmpty
        showCounts(); showSelected()
    }

    /// A reload may have changed what a folder extension's panel shows (an agent edits it, then `kelp ext reload`):
    /// those are made again. Built-in panels stay as they are.
    private func forgetFolderPanels() {
        let builtin = Set(app.extensions.extensions.filter(\.builtin).map(\.id))
        for p in panels where !builtin.contains(p.extensionId) { made[p.id]?.view.removeFromSuperview(); made[p.id]?.removeFromParent(); made[p.id] = nil }
    }

    private func showCounts() {
        for (i, p) in panels.enumerated() where counts.indices.contains(i) {
            let n = p.badge?() ?? 0
            counts[i].count = n
            buttons[i].toolTip = n > 0 ? "\(loc(p.title)) (\(n))" : loc(p.title)
        }
    }

    @objc private func selected(_ b: NSButton) {
        guard panels.indices.contains(b.tag) else { return }
        app.workbench.inspectorPanel = panels[b.tag].id
        showSelected()   // the shown panel's icon again: its state stays on
    }

    private func ids(_ key: String) -> [String] { app.settings.value(key)?.array?.compactMap(\.string) ?? [] }

    /// A dragged icon takes the slot under the pointer (`x` in the row); the others slide aside.
    private func move(_ b: NSButton, to x: CGFloat) {
        var views = selector.arrangedSubviews; views.removeAll { $0 === b }
        let next = views.first { !$0.isHidden && $0.frame.midX > x }
        let i = next.flatMap { n in views.firstIndex { $0 === n } } ?? views.count
        guard selector.arrangedSubviews.firstIndex(of: b) != i else { return }
        selector.removeArrangedSubview(b); selector.insertArrangedSubview(b, at: i)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15; ctx.allowsImplicitAnimation = true
            selector.layoutSubtreeIfNeeded()
        }
    }

    private func saveOrder() {
        let order = selector.arrangedSubviews.compactMap { v in buttons.firstIndex { $0 === v }.map { panels[$0].id } }
        app.settings.set(Self.orderKey, .array(order.map(JSONValue.string)))
    }

    /// The row's right-click menu (on an icon or the band around it): which icons show, where the row sits, auto-hide.
    private func rowMenu(_ e: NSEvent) -> NSMenu? {
        let p = view.convert(e.locationInWindow, from: nil)
        let band = view.bounds.height - WindowBar.height
        guard (band - TabStrip.height...band).contains(p.y) || (selector.frame.minY...selector.frame.maxY).contains(p.y) else { return nil }
        let s = app.settings, hidden = Set(ids(Self.hiddenKey)), m = NSMenu()
        m.addItem(.sectionHeader(title: String(localized: "Icons")))
        for panel in panels {
            m.addItem(item(loc(panel.title), #selector(toggleIcon(_:)), panel.id, on: !hidden.contains(panel.id)))
        }
        let at = s.string("workbench.inspectorIconsPosition") == "bottom" ? "bottom" : "top"
        m.addItem(.sectionHeader(title: String(localized: "Position")))
        for v in ["top", "bottom"] { m.addItem(item(loc(v.capitalized), #selector(setChoice(_:)), ("workbench.inspectorIconsPosition", v), on: at == v)) }
        let side = ["left", "right"].contains(s.string("workbench.inspectorIcons")) ? s.string("workbench.inspectorIcons") : "center"
        m.addItem(.sectionHeader(title: String(localized: "Alignment")))
        for v in ["left", "center", "right"] { m.addItem(item(loc(v.capitalized), #selector(setChoice(_:)), ("workbench.inspectorIcons", v), on: side == v)) }
        m.addItem(.separator())
        m.addItem(item(String(localized: "Auto-Hide Inspector"), #selector(toggleAutoHide), nil, on: s.bool("workbench.inspector.autoHide") == true))
        return m
    }

    private func item(_ title: String, _ action: Selector, _ value: Any?, on: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self; i.representedObject = value; i.state = on ? .on : .off
        return i
    }

    @objc private func toggleIcon(_ i: NSMenuItem) {
        guard let id = i.representedObject as? String else { return }
        var hidden = ids(Self.hiddenKey)
        if let k = hidden.firstIndex(of: id) { hidden.remove(at: k) } else { hidden.append(id) }
        app.settings.set(Self.hiddenKey, hidden.isEmpty ? nil : .array(hidden.map(JSONValue.string)))
        // Hiding the shown panel's icon shows the first panel that still has one.
        let shown = panels.first { $0.id == app.workbench.inspectorPanel } ?? panels.first
        if shown?.id == id, hidden.contains(id), let next = panels.first(where: { !hidden.contains($0.id) }) { app.workbench.inspectorPanel = next.id }
    }

    @objc private func setChoice(_ i: NSMenuItem) {
        guard let (key, v) = i.representedObject as? (String, String) else { return }
        app.settings.set(key, .string(v))
    }

    @objc private func toggleAutoHide() {
        app.settings.set("workbench.inspector.autoHide", .bool(app.settings.bool("workbench.inspector.autoHide") != true))
    }

    /// Shows a panel by id (menus and commands use this too).
    func show(panel id: String) { app.workbench.inspectorPanel = id }
    /// A panel already built (they're built when first shown).
    func built(_ id: String) -> NSViewController? { made[id] }

    private func showSelected() {
        guard !panels.isEmpty else { host.subviews.forEach { $0.removeFromSuperview() }; return }
        let i = panels.firstIndex { $0.id == app.workbench.inspectorPanel } ?? 0
        for (j, b) in buttons.enumerated() { b.state = j == i ? .on : .off }
        let p = panels[i]
        panelTitle.stringValue = loc(p.title)
        // A collapsed inspector builds nothing: the panel is made when it shows (a hidden Source Control runs no git).
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        let vc = made[p.id] ?? p.make()
        if made[p.id] == nil { made[p.id] = vc; addChild(vc) }
        guard vc.view.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(vc.view)
        // The panel follows the inspector's width but can't push it: a panel wider than its minimum is clipped instead
        // of shrinking the editor (extension panels with long lines included).
        let follow = vc.view.widthAnchor.constraint(equalTo: host.widthAnchor); follow.priority = .defaultHigh
        NSLayoutConstraint.activate([vc.view.topAnchor.constraint(equalTo: host.topAnchor), vc.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     vc.view.leadingAnchor.constraint(equalTo: host.leadingAnchor), follow])
    }
}

/// The inspector's view: a right-click on the icon row's band opens the row's menu.
private final class InspectorView: NSView {
    var rowMenu: ((NSEvent) -> NSMenu?)?
    /// On screen: in a window and not collapsed (a collapsed split view item is hidden).
    var onShow: (() -> Void)?
    override func menu(for e: NSEvent) -> NSMenu? { rowMenu?(e) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onShow?() }
    override func viewDidUnhide() { super.viewDidUnhide(); onShow?() }
}

/// A soft capsule behind a row of icons: the inspector's panels, a pane's new-agent and "+" buttons.
final class CapsuleStack: NSStackView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
}

/// A panel's icon, a segment of the capsule: a click shows the panel, a drag moves the icon along the row (`moved`
/// with the pointer's x in the row, `dropped` on release). The shown panel's icon sits on a fill of its own.
private final class PanelIcon: NSButton {
    var moved: ((CGFloat) -> Void)?
    var dropped: (() -> Void)?
    var contextMenu: ((NSEvent) -> NSMenu?)?
    private var hover = false { didSet { needsDisplay = true } }

    convenience init(_ symbol: String, _ label: String) {
        self.init(frame: .zero)
        image = .symbol(symbol, label); imagePosition = .imageOnly; title = ""; toolTip = label
        isBordered = false; setButtonType(.pushOnPushOff); wantsLayer = true
        symbolConfiguration = .init(pointSize: 14, weight: .regular); imageScaling = .scaleProportionallyDown
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let on = state == .on
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(on ? 0.14 : hover ? 0.06 : 0).cgColor
        contentTintColor = on ? .labelColor : .secondaryLabelColor
    }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    /// The count badge sits over the pill's corner; a button clips to its rounded layer (and sets this back to true on display).
    override var clipsToBounds: Bool { get { false } set {} }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }

    override func menu(for e: NSEvent) -> NSMenu? { contextMenu?(e) }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control), let m = menu(for: e) { return NSMenu.popUpContextMenu(m, with: e, for: self) }
        guard let w = window, let row = superview else { return super.mouseDown(with: e) }
        isHighlighted = true; defer { isHighlighted = false }
        var dragging = false, at = e.locationInWindow
        while let next = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            at = next.locationInWindow
            if next.type == .leftMouseUp { break }
            guard dragging || abs(at.x - e.locationInWindow.x) > 3 else { continue }
            dragging = true; isHighlighted = false
            moved?(row.convert(at, from: nil).x)
        }
        if dragging { dropped?() } else if bounds.contains(convert(at, from: nil)) { sendAction(action, to: target) }
    }
}

/// A panel's number on its icon (Source Control: changed files), a capsule in the accent colour.
private final class CountBadge: NSView {
    var count = 0 { didSet { isHidden = count == 0; invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var text: NSAttributedString {
        NSAttributedString(string: count > 99 ? "99+" : "\(count)",
                           attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white])
    }
    init() { super.init(frame: .zero); isHidden = true }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: max(13, ceil(text.size().width) + 7), height: 13) }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }   // clicks go to the icon
    override func draw(_ r: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let s = text.size()
        text.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }
}

/// SwiftUI panel in an AppKit host.
@MainActor
func hosting<V: View>(_ v: V) -> NSViewController {
    // Filling the panel from the top: content shorter than the panel would otherwise float in its middle.
    let h = NSHostingController(rootView: v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    h.sizingOptions = []   // a panel fills the space it's given; it must never resize the window to its ideal size
    return h
}
