import AppKit
import Core

/// Right-hand side: a mode bar (Terminals / Review / ...) over the active mode's view.
@MainActor
final class ContentViewController: NSViewController {
    let workspace = WorkspaceViewController()
    let diff = DiffViewController()
    let files = FilesViewController()
    private var modes: [(String, NSViewController)] = []
    private let bar = NSSegmentedControl()
    private let host = NSView()
    private(set) var worktreeId: String?

    override func loadView() {
        modes = [("Terminals", workspace), ("Review", diff), ("Files", files)]
        bar.segmentCount = modes.count
        for (i, m) in modes.enumerated() { bar.setLabel(m.0, forSegment: i) }
        bar.selectedSegment = 0; bar.target = self; bar.action = #selector(modeChanged); bar.segmentStyle = .texturedRounded
        bar.translatesAutoresizingMaskIntoConstraints = false; host.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView(); v.addSubview(bar); v.addSubview(host)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: v.topAnchor, constant: 6), bar.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            host.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6), host.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: v.trailingAnchor), host.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
        modes.forEach { addChild($0.1) }
        diff.currentSession = { [weak self] in self?.workspace.currentSessionId }
        files.currentSession = { [weak self] in self?.workspace.currentSessionId }
        select(0)
    }

    /// Add a mode (Files, Browser, ... registered by later features).
    func register(_ name: String, _ vc: NSViewController) {
        modes.append((name, vc)); addChild(vc)
        bar.segmentCount = modes.count; bar.setLabel(name, forSegment: modes.count - 1)
    }

    @objc private func modeChanged() { select(bar.selectedSegment) }
    func select(_ i: Int) {
        guard modes.indices.contains(i) else { return }
        bar.selectedSegment = i
        host.subviews.forEach { $0.removeFromSuperview() }
        let v = modes[i].1.view; v.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: host.topAnchor), v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: host.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        if let m = modes[i].1 as? WorktreeAware { m.show(worktree: worktreeId) }
    }
    func select(named n: String) { if let i = modes.firstIndex(where: { $0.0 == n }) { select(i) } }
    var currentMode: String { modes[bar.selectedSegment].0 }

    func show(worktree id: String?) {
        worktreeId = id
        workspace.show(worktree: id)
        for m in modes where m.1 !== workspace { (m.1 as? WorktreeAware)?.show(worktree: id) }
    }
}

@MainActor protocol WorktreeAware: AnyObject { func show(worktree id: String?) }
extension DiffViewController: WorktreeAware {}
