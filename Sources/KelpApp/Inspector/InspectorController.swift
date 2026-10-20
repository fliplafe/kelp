import AppKit
import SwiftUI

/// Right side: a row of panel icons (from extensions) over the selected panel — a scope bar like Mail's and Finder's:
/// plain icons, the selected one on a soft background. The row is the inspector's part of the title bar.
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
    private let empty = NSTextField(labelWithString: String(localized: "No panels — enable extensions in Settings."))

    override func loadView() {
        let v = NSView()
        selector.spacing = 4
        empty.textColor = .secondaryLabelColor; empty.alignment = .center
        host.clipsToBounds = true
        let sep = NSBox(); sep.boxType = .separator
        for x in [selector, sep, host, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        align = ["left": selector.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
                 "center": selector.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                 "right": selector.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -44)]
        align.values.forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate([
            // Level with the tabs, the full height of the title bar; clear of the inspector toggle in the corner.
            selector.centerYAnchor.constraint(equalTo: v.topAnchor, constant: TabStrip.height / 2),
            selector.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 8), selector.heightAnchor.constraint(equalToConstant: TabStrip.height),
            selector.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -44),
            sep.bottomAnchor.constraint(equalTo: v.topAnchor, constant: TabStrip.height), sep.leadingAnchor.constraint(equalTo: v.leadingAnchor), sep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            host.topAnchor.constraint(equalTo: sep.bottomAnchor), host.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: v.trailingAnchor), host.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        view = v
        track { ExtensionRegistry.shared.revision } changed: { [weak self] _ in self?.rebuild() }
        track { Workbench.shared.inspectorPanel } changed: { [weak self] _ in self?.showSelected() }
        track { ExtensionRegistry.shared.all.panels.map { $0.badge?() ?? 0 } } changed: { [weak self] _ in self?.showCounts() }
        track { SettingsStore.shared.string("workbench.inspectorIcons") } changed: { [weak self] in
            guard let self else { return }
            let want = self.align[$0 ?? ""] == nil ? "center" : $0 ?? ""
            for (k, c) in self.align { c.isActive = k == want }
        }
        // Panels are built with the text size of the moment: rebuilt when it changes.
        NotificationCenter.default.addObserver(forName: .kelpTextSize, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (_, vc) in self.made { vc.view.removeFromSuperview(); vc.removeFromParent() }
                self.made = [:]; self.showSelected()
            }
        }
    }

    private func rebuild() {
        panels = ExtensionRegistry.shared.all.panels
        let ids = Set(panels.map(\.id))
        for k in made.keys where !ids.contains(k) { made[k]?.view.removeFromSuperview(); made[k]?.removeFromParent(); made[k] = nil }
        buttons.forEach { $0.removeFromSuperview() }
        counts = []
        buttons = panels.enumerated().map { i, p in
            let b = NSButton(image: .symbol(p.icon, loc(p.title)), target: self, action: #selector(selected(_:)))
            b.bezelStyle = .recessed; b.setButtonType(.pushOnPushOff); b.showsBorderOnlyWhileMouseInside = true
            b.toolTip = loc(p.title); b.tag = i; b.imageScaling = .scaleProportionallyDown
            b.symbolConfiguration = .init(pointSize: 15, weight: .medium)   // 13 pt regular read as hairlines in the title bar
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
    }

    /// Shows a panel by id (menus and commands use this too).
    func show(panel id: String) { Workbench.shared.inspectorPanel = id }

    private func showSelected() {
        guard !panels.isEmpty else { host.subviews.forEach { $0.removeFromSuperview() }; return }
        let i = panels.firstIndex { $0.id == Workbench.shared.inspectorPanel } ?? 0
        for (j, b) in buttons.enumerated() { b.state = j == i ? .on : .off }
        let p = panels[i]
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
