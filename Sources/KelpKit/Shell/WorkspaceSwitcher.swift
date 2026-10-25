import AppKit
import Core

/// ⌃Tab, like ⌘Tab for apps: hold ⌃ and press Tab to walk the workspaces you used last (⇧ goes back, ↑↓ too), let go
/// or click a row to switch; Esc stays. A quick ⌃Tab flips to the previous workspace. The one on screen isn't listed, so
/// the first row is where you were before. Each row says what's there: project and branch,
/// changes not committed, the pull request, and the agent that matters most (what it's doing and its last words).
@MainActor
final class WorkspaceSwitcher {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    private var panel: NSPanel?
    private var monitor: Any?
    private var items: [Worktree] = []
    private var index = 0
    private var rows: [NSView] = []
    private var pointerFrom: NSPoint?
    private var stepped: TimeInterval?

    /// The menu's ⌃Tab / ⌃⇧Tab.
    func step(_ by: Int) {
        // With the panel open a Tab reaches both its keys and the menu's ⌃Tab: one press, one row.
        if let e = NSApp.currentEvent, e.type == .keyDown {
            guard e.timestamp != stepped else { return }
            stepped = e.timestamp
        }
        let opening = panel == nil
        if opening { open() }
        guard !items.isEmpty else { return }
        index = opening ? (by > 0 ? 0 : items.count - 1) : (index + by + items.count) % items.count
        highlight()
        if !NSEvent.modifierFlags.contains(.control) { commit() }   // already let go: a quick flip
    }

    private func open() {
        let m = app, wb = app.workbench
        let live = app.workbench.workspacesInOrder
        // Ones not on screen since Kelp started keeping the order: by their agents' last stir, else when they were made.
        let stirred = live.map { w in (w.id, m.sessions.filter { $0.worktreeId == w.id }.map { $0.statusAt ?? $0.createdAt }.max() ?? w.createdAt) }
        var order: [String] = []
        for id in wb.recentWorkspaces + stirred.sorted { $0.1 > $1.1 }.map(\.0) where id != wb.workspaceId && !order.contains(id) && live.contains(where: { $0.id == id }) {
            order.append(id)
        }
        items = order.compactMap(m.worktree)
        guard !items.isEmpty, let window = app.workbench.window?.window else {
            NSSound.beep()
            return
        }

        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 2
        list.alignment = .leading
        list.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        rows = items.enumerated().map { i, w in
            let r = row(w)
            r.onClick = { [weak self] in self?.index = i; self?.commit() }
            r.onHover = { [weak self] in self?.hover(i) }
            return r
        }
        pointerFrom = NSEvent.mouseLocation
        rows.forEach { list.addArrangedSubview($0); $0.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true }
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.pin(list); list.widthAnchor.constraint(equalToConstant: 460).isActive = true
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
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

    /// The pointer picks once it really moves: the panel opens under it, and brushing the trackpad shouldn't take the pick.
    private func hover(_ i: Int) {
        if let p = pointerFrom {
            guard hypot(NSEvent.mouseLocation.x - p.x, NSEvent.mouseLocation.y - p.y) > 10 else { return }
            pointerFrom = nil
        }
        guard index != i else { return }
        index = i
        highlight()
    }

    private func commit() {
        let pick = items.indices.contains(index) ? items[index].id : nil
        close()
        if let pick { app.workbench.show(workspace: pick) }
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
            for t in labels(r) where t.tag != 2 {
                t.textColor = i == index ? .alternateSelectedControlTextColor : (t.tag == 1 ? .secondaryLabelColor : .labelColor)
            }
        }
    }

    private func row(_ w: Worktree) -> SwitcherRow {
        let m = app
        let agents = m.sessions.filter { $0.worktreeId == w.id && $0.agent != "shell" && $0.status != .exited }
        let top = AgentStatus.mostUrgent(agents.map(SidebarCell.shownStatus))
        let lead = agents.filter { SidebarCell.shownStatus($0) == top }.max { ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt) }
        let mark = StatusMark(size: 14)
        mark.status = top
        mark.unread = agents.contains { SidebarCell.shownStatus($0) == top && $0.unread }

        let icon = NSImageView(image: .symbol("folder"))
        if let r = m.repo(w.repoId) { ProjectIcon.show(r.path, in: icon) }
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true; icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let name = label(w.displayName, .systemFont(ofSize: 14, weight: .medium))
        let repo = m.repo(w.repoId)
        let place = label([repo?.name, w.path == repo?.path || w.branch == w.displayName ? nil : w.branch].compactMap { $0 }.joined(separator: " · "),
            .systemFont(ofSize: 12), tag: 1)
        let folder = app.rowBadges.folder(workspace: w.id) ?? app.rowBadges.folder(project: w.repoId)
        let changes = label("", .uiDigits(11), tag: 2), pr = label("", .uiDigits(11), tag: 2)
        if let c = folder.flatMap({ RowBadges.changes(app.rowBadges.stats[$0.id], compact: true) }) {
            changes.attributedStringValue = c
        } else {
            changes.isHidden = true
        }
        if let p = folder.flatMap({ RowBadges.pr(app.rowBadges.prs[$0.id]) }) { pr.attributedStringValue = p.0 } else { pr.isHidden = true }
        let when = label(shortAgo(lead.map { $0.statusAt ?? $0.createdAt }), .monospacedDigitSystemFont(ofSize: 11, weight: .regular), tag: 1)
        let top1 = NSStackView(views: [name, place, NSView(), changes, pr, when, mark])
        top1.spacing = 8
        top1.alignment = .centerY
        top1.detachesHiddenViews = true

        // "Claude Code · Needs your input — Which test runner?  +1 more": the agent the mark is for.
        let others = agents.count - 1
        let said = lead.map { s in
            [app.catalog.displayName(s) + " · " + s.statusWords, s.summary].filter { !$0.isEmpty }.joined(separator: " — ")
                + (others > 0 ? "  " + String(localized: "+\(others) more") : "")
        } ?? String(localized: "No agents")
        let detail = label(said, .systemFont(ofSize: 12), tag: 1)
        let text = NSStackView(views: [top1, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        top1.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true

        let r = SwitcherRow(views: [icon, text])
        r.spacing = 10
        r.alignment = .centerY
        r.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        r.wantsLayer = true; r.layer?.cornerRadius = 7
        return r
    }

    private func label(_ s: String, _ font: NSFont, tag: Int = 0) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.tag = tag
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(tag == 0 ? .init(400) : .defaultLow, for: .horizontal)
        return t
    }
}

/// A switcher row the pointer picks, ⌃ still held as with ⌘Tab: moving over it highlights it (letting go of ⌃ goes
/// there), a click goes at once. The click is the row's, not its labels'.
private final class SwitcherRow: NSStackView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    override func viewDidMoveToWindow() {
        if trackingAreas.isEmpty { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)) }
    }
    override func mouseMoved(with e: NSEvent) { onHover?() }
    override func hitTest(_ p: NSPoint) -> NSView? { frame.contains(p) ? self : nil }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { onClick?() }
    override func rightMouseDown(with e: NSEvent) { onClick?() }   // ⌃-click comes as a right click
}
