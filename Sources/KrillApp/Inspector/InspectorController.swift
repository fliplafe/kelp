import AppKit
import SwiftUI

/// Right side: a row of panel icons (from extensions) over the selected panel.
@MainActor
final class InspectorController: NSViewController {
    private let selector = NSSegmentedControl()
    private let host = NSView()
    private var panels: [PanelSpec] = []
    private var made: [String: NSViewController] = [:]
    private let empty = NSTextField(labelWithString: "No panels — enable extensions in Settings.")

    override func loadView() {
        let v = NSView()
        selector.segmentStyle = .automatic; selector.trackingMode = .selectOne; selector.controlSize = .regular
        selector.target = self; selector.action = #selector(selected)
        empty.textColor = .secondaryLabelColor; empty.alignment = .center
        let sep = NSBox(); sep.boxType = .separator
        for x in [selector, sep, host, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            selector.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: 6), selector.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            selector.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 8),
            sep.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 6), sep.leadingAnchor.constraint(equalTo: v.leadingAnchor), sep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
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
        selector.segmentCount = panels.count
        for (i, p) in panels.enumerated() {
            selector.setImage(.symbol(p.icon, p.title), forSegment: i)
            selector.setToolTip(p.title, forSegment: i)
            selector.setWidth(30, forSegment: i)
        }
        selector.isHidden = panels.isEmpty; empty.isHidden = !panels.isEmpty
        showSelected()
    }

    @objc private func selected() {
        guard panels.indices.contains(selector.selectedSegment) else { return }
        Workbench.shared.inspectorPanel = panels[selector.selectedSegment].id
    }

    /// Shows a panel by id (menus and commands use this too).
    func show(panel id: String) { Workbench.shared.inspectorPanel = id }

    private func showSelected() {
        guard !panels.isEmpty else { host.subviews.forEach { $0.removeFromSuperview() }; return }
        let i = panels.firstIndex { $0.id == Workbench.shared.inspectorPanel } ?? 0
        selector.selectedSegment = i
        let p = panels[i]
        let vc = made[p.id] ?? p.make()
        if made[p.id] == nil { made[p.id] = vc; addChild(vc) }
        guard vc.view.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(vc.view)
        NSLayoutConstraint.activate([vc.view.topAnchor.constraint(equalTo: host.topAnchor), vc.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     vc.view.leadingAnchor.constraint(equalTo: host.leadingAnchor), vc.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
    }
}

/// SwiftUI panel in an AppKit host.
@MainActor
func hosting<V: View>(_ v: V) -> NSViewController {
    let h = NSHostingController(rootView: v)
    h.sizingOptions = []   // a panel fills the space it's given; it must never resize the window to its ideal size
    return h
}
