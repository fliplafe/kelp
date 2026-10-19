import AppKit
import SwiftUI

/// Right side: a row of panel icons (from extensions) over the selected panel — a scope bar like Mail's and Finder's:
/// plain icons, the selected one on a soft background.
@MainActor
final class InspectorController: NSViewController {
    private let selector = NSStackView()
    private var buttons: [NSButton] = []
    private let host = NSView()   // clips: see showSelected
    private var panels: [PanelSpec] = []
    private var made: [String: NSViewController] = [:]
    private let empty = NSTextField(labelWithString: "No panels — enable extensions in Settings.")

    override func loadView() {
        let v = NSView()
        selector.spacing = 2
        empty.textColor = .secondaryLabelColor; empty.alignment = .center
        host.clipsToBounds = true
        let sep = NSBox(); sep.boxType = .separator
        for x in [selector, sep, host, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            selector.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: 2), selector.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            selector.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 8), selector.heightAnchor.constraint(equalToConstant: 26),
            sep.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 2), sep.leadingAnchor.constraint(equalTo: v.leadingAnchor), sep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            host.topAnchor.constraint(equalTo: sep.bottomAnchor), host.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: v.trailingAnchor), host.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        view = v
        track { ExtensionRegistry.shared.revision } changed: { [weak self] _ in self?.rebuild() }
        track { Workbench.shared.inspectorPanel } changed: { [weak self] _ in self?.showSelected() }
    }

    private func rebuild() {
        panels = ExtensionRegistry.shared.all.panels
        let ids = Set(panels.map(\.id))
        for k in made.keys where !ids.contains(k) { made[k]?.view.removeFromSuperview(); made[k]?.removeFromParent(); made[k] = nil }
        buttons.forEach { $0.removeFromSuperview() }
        buttons = panels.enumerated().map { i, p in
            let b = NSButton(image: .symbol(p.icon, p.title), target: self, action: #selector(selected(_:)))
            b.bezelStyle = .recessed; b.setButtonType(.pushOnPushOff); b.showsBorderOnlyWhileMouseInside = true
            b.toolTip = p.title; b.tag = i; b.imageScaling = .scaleProportionallyDown
            b.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            selector.addArrangedSubview(b)
            return b
        }
        selector.isHidden = panels.isEmpty; empty.isHidden = !panels.isEmpty
        showSelected()
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

/// SwiftUI panel in an AppKit host.
@MainActor
func hosting<V: View>(_ v: V) -> NSViewController {
    // Filling the panel from the top: content shorter than the panel would otherwise float in its middle.
    let h = NSHostingController(rootView: v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    h.sizingOptions = []   // a panel fills the space it's given; it must never resize the window to its ideal size
    return h
}
