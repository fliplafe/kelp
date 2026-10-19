import AppKit
import Core

/// ⌃Tab, like ⌘Tab for apps: hold ⌃ and press Tab to walk the workspaces you used last (⇧ goes back, ↑↓ too), let go
/// to switch; Esc stays. A quick ⌃Tab flips to the previous workspace.
@MainActor
final class WorkspaceSwitcher {
    static let shared = WorkspaceSwitcher()
    private var panel: NSPanel?
    private var monitor: Any?
    private var items: [Worktree] = []
    private var index = 0
    private var rows: [NSView] = []

    /// The menu's ⌃Tab / ⌃⇧Tab.
    func step(_ by: Int) {
        if panel == nil { open() }
        guard !items.isEmpty else { return }
        index = (index + by + items.count) % items.count
        highlight()
        if !NSEvent.modifierFlags.contains(.control) { commit() }   // already let go: a quick flip
    }

    private func open() {
        let m = AppModel.shared, wb = Workbench.shared
        let live = Workbench.workspacesInOrder
        var order: [String] = []
        for id in [wb.workspaceId].compactMap({ $0 }) + wb.visits.reversed() where !order.contains(id) && live.contains(where: { $0.id == id }) { order.append(id) }
        order += live.map(\.id).filter { !order.contains($0) }
        items = order.compactMap(m.worktree)
        guard items.count > 1, let window = Workbench.window?.window else { items = []; NSSound.beep(); return }
        index = 0

        let list = NSStackView(); list.orientation = .vertical; list.spacing = 2; list.alignment = .leading
        list.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        rows = items.map { row($0) }
        rows.forEach { list.addArrangedSubview($0); $0.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true }
        let fx = NSVisualEffectView(); fx.material = .hudWindow; fx.state = .active; fx.wantsLayer = true; fx.layer?.cornerRadius = 12
        list.translatesAutoresizingMaskIntoConstraints = false; fx.addSubview(list)
        NSLayoutConstraint.activate([list.topAnchor.constraint(equalTo: fx.topAnchor), list.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
                                     list.leadingAnchor.constraint(equalTo: fx.leadingAnchor), list.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     list.widthAnchor.constraint(equalToConstant: 360)])
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .popUpMenu
        p.contentView = fx
        fx.layoutSubtreeIfNeeded()
        let size = fx.fittingSize, f = window.frame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.1, width: size.width, height: size.height), display: true)
        window.addChildWindow(p, ordered: .above)
        panel = p
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in self?.handle(e) ?? e }
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        if e.type == .flagsChanged { if !e.modifierFlags.contains(.control) { commit() }; return e }
        switch e.keyCode {
        case 48: step(e.modifierFlags.contains(.shift) ? -1 : 1)   // Tab
        case 125: step(1)    // ↓
        case 126: step(-1)   // ↑
        case 36, 76: commit()
        case 53: close()     // Esc
        default: break
        }
        return nil   // while it's open, keys belong to it
    }

    private func commit() {
        let pick = items.indices.contains(index) ? items[index].id : nil
        close()
        if let pick { Workbench.show(workspace: pick) }
    }

    private func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let p = panel { p.parent?.removeChildWindow(p); p.orderOut(nil) }
        panel = nil; rows = []
    }

    private func highlight() {
        for (i, r) in rows.enumerated() {
            r.layer?.backgroundColor = i == index ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.85).cgColor : NSColor.clear.cgColor
            for case let t as NSTextField in r.subviews.flatMap({ [$0] + $0.subviews }) { t.textColor = i == index ? .white : (t.tag == 1 ? .secondaryLabelColor : .labelColor) }
        }
    }

    private func row(_ w: Worktree) -> NSView {
        let m = AppModel.shared
        let agents = m.sessions.filter { $0.worktreeId == w.id && $0.agent != "shell" && $0.status != .exited }
        let mark = StatusMark(size: 14); mark.status = AgentStatus.mostUrgent(agents.map(\.status)); mark.unread = agents.contains(where: \.unread)
        let name = NSTextField(labelWithString: w.displayName); name.font = .systemFont(ofSize: 14, weight: .medium); name.lineBreakMode = .byTruncatingTail
        let place = NSTextField(labelWithString: m.repo(w.repoId)?.name ?? ""); place.font = .systemFont(ofSize: 12); place.tag = 1
        let lead = agents.max { ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt) }
        let when = NSTextField(labelWithString: lead.map { "\(AgentCatalog.displayName($0)) · \(shortAgo($0.statusAt ?? $0.createdAt))" } ?? "")
        when.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); when.tag = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let r = NSStackView(views: [name, place, NSView(), when, mark]); r.spacing = 8; r.alignment = .centerY
        r.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        r.wantsLayer = true; r.layer?.cornerRadius = 7
        return r
    }
}
