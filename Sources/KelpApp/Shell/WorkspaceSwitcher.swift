import AppKit
import Core

/// ⌃Tab, like ⌘Tab for apps: hold ⌃ and press Tab to walk the workspaces you used last (⇧ goes back, ↑↓ too), let go
/// to switch; Esc stays. A quick ⌃Tab flips to the previous workspace. Each row says what's there: project and branch,
/// changes not committed, the pull request, and the agent that matters most (what it's doing and its last words).
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
        for id in [wb.workspaceId].compactMap({ $0 }) + wb.history.visits.reversed() where !order.contains(id) && live.contains(where: { $0.id == id }) { order.append(id) }
        order += live.map(\.id).filter { !order.contains($0) }
        items = order.compactMap(m.worktree)
        guard items.count > 1, let window = Workbench.window?.window else { items = []; NSSound.beep(); return }
        index = 0

        let list = NSStackView(); list.orientation = .vertical; list.spacing = 2; list.alignment = .leading
        list.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        rows = items.map { row($0) }
        rows.forEach { list.addArrangedSubview($0); $0.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true }
        let fx = NSVisualEffectView(); fx.material = .hudWindow; fx.state = .active; fx.wantsLayer = true; fx.layer?.cornerRadius = 12
        fx.pin(list); list.widthAnchor.constraint(equalToConstant: 460).isActive = true
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
        func labels(_ v: NSView) -> [NSTextField] { v.subviews.flatMap { [$0 as? NSTextField].compactMap { $0 } + labels($0) } }
        for (i, r) in rows.enumerated() {
            r.layer?.backgroundColor = i == index ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.85).cgColor : NSColor.clear.cgColor
            // Tag 2: coloured badges keep their colours.
            for t in labels(r) where t.tag != 2 { t.textColor = i == index ? .alternateSelectedControlTextColor : (t.tag == 1 ? .secondaryLabelColor : .labelColor) }
        }
    }

    private func row(_ w: Worktree) -> NSView {
        let m = AppModel.shared
        let agents = m.sessions.filter { $0.worktreeId == w.id && $0.agent != "shell" && $0.status != .exited }
        let top = AgentStatus.mostUrgent(agents.map(SidebarCell.shownStatus))
        let lead = agents.filter { SidebarCell.shownStatus($0) == top }.max { ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt) }
        let mark = StatusMark(size: 14); mark.status = top; mark.unread = agents.contains { SidebarCell.shownStatus($0) == top && $0.unread }

        let icon = NSImageView(image: m.repo(w.repoId).map { ProjectIcon.image(for: $0.path) } ?? .symbol("folder"))
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true; icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let name = label(w.displayName, .systemFont(ofSize: 14, weight: .medium))
        let repo = m.repo(w.repoId)
        let place = label([repo?.name, w.path == repo?.path || w.branch == w.displayName ? nil : w.branch].compactMap { $0 }.joined(separator: " · "),
            .systemFont(ofSize: 12), tag: 1)
        let folder = RowBadges.folder(workspace: w.id) ?? RowBadges.folder(project: w.repoId)
        let changes = label("", .uiDigits(11), tag: 2), pr = label("", .uiDigits(11), tag: 2)
        if let c = folder.flatMap({ RowBadges.changes(RowBadges.shared.stats[$0.id]) }) { changes.attributedStringValue = c } else { changes.isHidden = true }
        if let p = folder.flatMap({ RowBadges.pr(RowBadges.shared.prs[$0.id]) }) { pr.attributedStringValue = p.0 } else { pr.isHidden = true }
        let when = label(shortAgo(lead.map { $0.statusAt ?? $0.createdAt }), .monospacedDigitSystemFont(ofSize: 11, weight: .regular), tag: 1)
        let top1 = NSStackView(views: [name, place, NSView(), changes, pr, when, mark]); top1.spacing = 8; top1.alignment = .centerY
        top1.detachesHiddenViews = true

        // "Claude Code · Needs your input — Which test runner?  +1 more": the agent the mark is for.
        let others = agents.count - 1
        let said = lead.map { s in
            [AgentCatalog.displayName(s) + " · " + s.statusWords, s.summary].filter { !$0.isEmpty }.joined(separator: " — ")
                + (others > 0 ? "  " + String(localized: "+\(others) more") : "")
        } ?? String(localized: "No agents")
        let detail = label(said, .systemFont(ofSize: 12), tag: 1)
        let text = NSStackView(views: [top1, detail]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        top1.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true

        let r = NSStackView(views: [icon, text]); r.spacing = 10; r.alignment = .centerY
        r.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        r.wantsLayer = true; r.layer?.cornerRadius = 7
        return r
    }

    private func label(_ s: String, _ font: NSFont, tag: Int = 0) -> NSTextField {
        let t = NSTextField(labelWithString: s); t.font = font; t.tag = tag; t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(tag == 0 ? .init(400) : .defaultLow, for: .horizontal)
        return t
    }
}
