import AppKit
import SwiftUI
import Core

/// Right side: a row of panel icons (from extensions) over the selected panel — a scope bar like Mail's and Finder's:
/// plain icons, the selected one on a soft background. The row is the inspector's part of the window's second row,
/// or a bar under the panel. Icons are dragged into order; a right-click on the row hides them and moves the row.
@MainActor
final class InspectorController: NSViewController {
    private let selector = NSStackView()
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
    private let heading = NSTextField(labelWithString: "")   // the panel's name where the icons were, while they're at the bottom
    private let empty = NSTextField(labelWithString: String(localized: "No panels — enable extensions in Settings."))
    private static let orderKey = "workbench.inspector.panelOrder", hiddenKey = "workbench.inspector.hiddenPanels"

    override func loadView() {
        let v = InspectorView()
        v.rowMenu = { [weak self] in self?.rowMenu($0) }
        selector.spacing = 4
        empty.textColor = .secondaryLabelColor; empty.alignment = .center
        heading.font = .ui(NSFont.systemFontSize, weight: .semibold); heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail; heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.clipsToBounds = true
        let sep = NSBox(); sep.boxType = .separator; rowSep.boxType = .separator
        for x in [selector, sep, rowSep, heading, host, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        // The window bar lies over the inspector's top (it's the window's full height): its rows start under it.
        let under = NSLayoutGuide(); v.addLayoutGuide(under)
        under.topAnchor.constraint(equalTo: v.topAnchor, constant: WindowBar.height).isActive = true
        align = ["left": selector.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
                 "center": selector.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                 "right": selector.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8)]
        align.values.forEach { $0.priority = .defaultHigh }
        // Level with the tabs, the full height of their strip; or as tall, under the panel.
        top = [selector.centerYAnchor.constraint(equalTo: under.topAnchor, constant: TabStrip.height / 2), host.bottomAnchor.constraint(equalTo: v.bottomAnchor)]
        bottom = [selector.bottomAnchor.constraint(equalTo: v.bottomAnchor), rowSep.bottomAnchor.constraint(equalTo: selector.topAnchor),
                  host.bottomAnchor.constraint(equalTo: rowSep.topAnchor)]
        NSLayoutConstraint.activate([
            selector.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 8), selector.heightAnchor.constraint(equalToConstant: TabStrip.height),
            selector.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -8),
            sep.bottomAnchor.constraint(equalTo: under.topAnchor, constant: TabStrip.height), sep.leadingAnchor.constraint(equalTo: v.leadingAnchor), sep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            rowSep.leadingAnchor.constraint(equalTo: v.leadingAnchor), rowSep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            heading.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12), heading.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -8),
            heading.centerYAnchor.constraint(equalTo: under.topAnchor, constant: TabStrip.height / 2),
            host.topAnchor.constraint(equalTo: sep.bottomAnchor), host.leadingAnchor.constraint(equalTo: v.leadingAnchor), host.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        view = v
        // Panels are built with the text size of the moment: rebuilt when it changes (first, while none are built).
        track { SettingsStore.shared.string("workbench.textSize") } changed: { [weak self] _ in
            guard let self else { return }
            for (_, vc) in made { vc.view.removeFromSuperview(); vc.removeFromParent() }
            made = [:]; showSelected()
        }
        track { ExtensionRegistry.shared.revision } changed: { [weak self] _ in self?.rebuild() }
        track { [SettingsStore.shared.value(Self.orderKey), SettingsStore.shared.value(Self.hiddenKey)] } changed: { [weak self] _ in self?.rebuild() }
        track { SettingsStore.shared.string("workbench.inspectorIconsPosition") == "bottom" } changed: { [weak self] in
            guard let self else { return }
            NSLayoutConstraint.deactivate($0 ? self.top : self.bottom); NSLayoutConstraint.activate($0 ? self.bottom : self.top)
            self.rowSep.isHidden = !$0; self.heading.isHidden = !$0
        }
        track { Workbench.shared.inspectorPanel } changed: { [weak self] _ in self?.showSelected() }
        track { ExtensionRegistry.shared.all.panels.map { $0.badge?() ?? 0 } } changed: { [weak self] _ in self?.showCounts() }
        track { SettingsStore.shared.string("workbench.inspectorIcons") } changed: { [weak self] in
            guard let self else { return }
            let want = self.align[$0 ?? ""] == nil ? "center" : $0 ?? ""
            for (k, c) in self.align { c.isActive = k == want }
        }
    }

    private func rebuild() {
        // In the order the row was dragged into; panels it doesn't name yet follow in the registry's order.
        let order = ids(Self.orderKey), hidden = Set(ids(Self.hiddenKey))
        func rank(_ e: (offset: Int, element: PanelSpec)) -> (Int, Int) { (order.firstIndex(of: e.element.id) ?? .max, e.offset) }
        panels = ExtensionRegistry.shared.all.panels.enumerated().sorted { rank($0) < rank($1) }.map(\.element)
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
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
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

    private func showCounts() {
        for (i, p) in panels.enumerated() where counts.indices.contains(i) {
            let n = p.badge?() ?? 0
            counts[i].count = n
            buttons[i].toolTip = n > 0 ? "\(loc(p.title)) (\(n))" : loc(p.title)
        }
    }

    @objc private func selected(_ b: NSButton) {
        guard panels.indices.contains(b.tag) else { return }
        Workbench.shared.inspectorPanel = panels[b.tag].id
        showSelected()   // the shown panel's icon again: its state stays on
    }

    private func ids(_ key: String) -> [String] { SettingsStore.shared.value(key)?.array?.compactMap(\.string) ?? [] }

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
        SettingsStore.shared.set(Self.orderKey, .array(order.map(JSONValue.string)))
    }

    /// The row's right-click menu (on an icon or the band around it): which icons show, where the row sits, auto-hide.
    private func rowMenu(_ e: NSEvent) -> NSMenu? {
        let p = view.convert(e.locationInWindow, from: nil)
        let band = view.bounds.height - WindowBar.height
        guard (band - TabStrip.height...band).contains(p.y) || (selector.frame.minY...selector.frame.maxY).contains(p.y) else { return nil }
        let s = SettingsStore.shared, hidden = Set(ids(Self.hiddenKey)), m = NSMenu()
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
        SettingsStore.shared.set(Self.hiddenKey, hidden.isEmpty ? nil : .array(hidden.map(JSONValue.string)))
        // Hiding the shown panel's icon shows the first panel that still has one.
        let shown = panels.first { $0.id == Workbench.shared.inspectorPanel } ?? panels.first
        if shown?.id == id, hidden.contains(id), let next = panels.first(where: { !hidden.contains($0.id) }) { Workbench.shared.inspectorPanel = next.id }
    }

    @objc private func setChoice(_ i: NSMenuItem) {
        guard let (key, v) = i.representedObject as? (String, String) else { return }
        SettingsStore.shared.set(key, .string(v))
    }

    @objc private func toggleAutoHide() {
        SettingsStore.shared.set("workbench.inspector.autoHide", .bool(SettingsStore.shared.bool("workbench.inspector.autoHide") != true))
    }

    /// Shows a panel by id (menus and commands use this too).
    func show(panel id: String) { Workbench.shared.inspectorPanel = id }
    /// A panel already built (they're built when first shown).
    func built(_ id: String) -> NSViewController? { made[id] }

    private func showSelected() {
        guard !panels.isEmpty else { host.subviews.forEach { $0.removeFromSuperview() }; return }
        let i = panels.firstIndex { $0.id == Workbench.shared.inspectorPanel } ?? 0
        for (j, b) in buttons.enumerated() { b.state = j == i ? .on : .off }
        let p = panels[i]
        heading.stringValue = loc(p.title)
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
    override func menu(for e: NSEvent) -> NSMenu? { rowMenu?(e) }
}

/// A panel's icon, a title-bar button like the panel toggles: a click shows the panel, a drag moves the icon along
/// the row (`moved` with the pointer's x in the row, `dropped` on release).
private final class PanelIcon: NSButton {
    var moved: ((CGFloat) -> Void)?
    var dropped: (() -> Void)?
    var contextMenu: ((NSEvent) -> NSMenu?)?

    convenience init(_ symbol: String, _ label: String) {
        self.init(frame: .zero)
        image = .symbol(symbol, label); imagePosition = .imageOnly; title = ""; toolTip = label
        bezelStyle = .recessed; showsBorderOnlyWhileMouseInside = true; setButtonType(.pushOnPushOff)
        symbolConfiguration = .init(pointSize: 14, weight: .regular); imageScaling = .scaleProportionallyDown
    }

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
