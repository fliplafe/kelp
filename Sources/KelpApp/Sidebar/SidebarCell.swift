import AppKit
import Core
import WorkbenchKit

/// One row; `update()` re-reads the model, so status changes don't rebuild the outline.
@MainActor
final class SidebarCell: NSTableCellView {
    private let node: SidebarController.Node
    private weak var owner: SidebarController?
    private let app: AppModel
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    /// Right side: how long ago the state changed ("4m"), or on a project what needs you.
    private let trailing = NSTextField(labelWithString: "")
    private let mark = StatusMark(size: 14)
    private var add: NSButton?
    /// Lines not committed and the PR, for rows that stand for a folder (RowBadges); they go first when the row is short of room.
    private let changes = NSButton(), pr = NSButton()

    init(node: SidebarController.Node, owner: SidebarController) {
        self.node = node; self.owner = owner; app = owner.app
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        trailing.font = .uiDigits(11, weight: .regular); trailing.textColor = .secondaryLabelColor
        textField = title
        switch node.kind {
        case .project(let id):
            // A name, not a section label: what's under it is the project's. On the right only what needs doing.
            // Not the cell's textField: the source list would restyle it as a grey group heading.
            textField = nil; title.font = .ui(13, weight: .semibold); title.textColor = .labelColor
            trailing.font = .ui(11, weight: .semibold); trailing.textColor = .textOrange
            let b = ClosureButton(title: "") { [weak owner] in owner?.newWorkspace(id) }
            b.image = .symbol("plus", String(localized: "New Workspace")); b.isBordered = false; b.contentTintColor = .secondaryLabelColor
            b.toolTip = String(localized: "New workspace (⌘N)"); b.isHidden = true; add = b   // on hover, like Finder's sidebar
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true; icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            layout(row: [icon, title, NSView(), changes, pr, trailing, b])
        case .section:
            title.font = .ui(11, weight: .semibold); title.textColor = .secondaryLabelColor
            count.font = .ui(11); count.textColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            layout(row: [icon, title, count, NSView()])
        case .needs:
            title.font = .ui(13)
            count.font = .ui(11); count.textColor = .secondaryLabelColor; count.lineBreakMode = .byTruncatingTail
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true; icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let name = NSStackView(views: [title, count]); name.spacing = 6
            name.setClippingResistancePriority(.defaultLow, for: .horizontal); name.setHuggingPriority(.defaultLow, for: .horizontal)
            layout(row: [icon, name, trailing, mark])
        case .workspace:
            title.font = .ui(13)
            layout(row: [title, NSView(), changes, pr, trailing, mark])
        case .agent:
            title.font = .ui(13)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true; icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            layout(row: [icon, title, trailing, mark])
        }
        for v in [title, count] { v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        if case .needs = node.kind { count.setContentCompressionResistancePriority(.init(200), for: .horizontal) }   // the place gives way to the name
        for b in [changes, pr] { b.isBordered = false; b.title = ""; b.target = self }
        changes.action = #selector(openChanges); pr.action = #selector(openPR)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { add?.isHidden = false; fitBadges() }
    override func mouseExited(with e: NSEvent) { add?.isHidden = true; fitBadges() }

    private func layout(row: [NSView]) {
        let r = NSStackView(views: row); r.spacing = 6; r.alignment = .centerY
        r.detachesHiddenViews = true
        for v in row where v === changes || v === pr { r.setVisibilityPriority(.notVisible, for: v) }
        r.translatesAutoresizingMaskIntoConstraints = false; addSubview(r)
        NSLayoutConstraint.activate([r.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), r.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                                     r.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    /// The folder this row stands for, if any (RowBadges.folder).
    private var folder: Worktree? {
        switch node.kind {
        case .project(let id): app.rowBadges.folder(project: id)
        case .workspace(let id): app.rowBadges.folder(workspace: id)
        case .agent, .section, .needs: nil
        }
    }
    @objc private func openChanges() { if let w = folder { app.workbench.open(TabURI.diff(w.id), workspace: w.id) } }
    @objc private func openPR() { if let w = folder, let u = app.rowBadges.prs[w.id]?.url { app.workbench.open(u, workspace: w.id) } }

    /// The stack shows a badge only when there's something to say, and drops it first when the row is narrow.
    private func updateBadges() {
        let w = folder
        let c = w.flatMap { RowBadges.changes(app.rowBadges.stats[$0.id]) }
        let p = w.flatMap { RowBadges.pr(app.rowBadges.prs[$0.id]) }
        if let c { changes.attributedTitle = c; changes.toolTip = String(localized: "Not committed yet — click for the changes") }
        if let p { pr.attributedTitle = p.0; pr.toolTip = p.1 }
        hasBadge = (c != nil, p != nil)
        fitBadges()
    }
    private var hasBadge = (changes: false, pr: false)

    /// Badges show while the name fits beside them: they step aside before it truncates (left to itself the stack
    /// squeezes the name instead: "kdrde…  +2 −1").
    private func fitBadges() {
        guard let r = changes.superview as? NSStackView else { return }
        let others = r.views.filter { $0 !== changes && $0 !== pr && !$0.isHidden }
        var room = bounds.width - 8 - others.reduce(0) { $0 + max(0, $1.intrinsicContentSize.width) + r.spacing }
        for (b, has) in [(changes, hasBadge.changes), (pr, hasBadge.pr)] {
            let need = b.intrinsicContentSize.width + r.spacing, show = has && room >= need
            if show { room -= need }
            r.setVisibilityPriority(show ? .mustHold : .notVisible, for: b)
        }
    }
    override func setFrameSize(_ s: NSSize) {
        let old = frame.width
        super.setFrameSize(s)
        if s.width != old { fitBadges() }
    }

    func update() {
        updateBadges()
        let m = app
        func live(_ wid: String) -> [Session] { m.sessions.filter { $0.worktreeId == wid && $0.status != .exited && $0.agent != "shell" } }
        switch node.kind {
        case .project(let id):
            let r = m.repo(id)
            let missing = r.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
            if let r, !missing { ProjectIcon.show(r.path, in: icon) } else { icon.image = missing ? .symbol("questionmark.folder") : nil }
            icon.contentTintColor = .secondaryLabelColor
            title.stringValue = r?.name ?? ""
            toolTip = missing ? String(localized: "\(r?.path ?? "") isn't there anymore. Right-click › Locate… if it moved.") : r?.path
            // Who needs you is on the agents' own rows and in the line above the projects, not repeated here.
            trailing.stringValue = missing ? String(localized: "Folder missing") : ""
        case .section(let name):
            let needs = name == "Needs You"
            icon.image = .symbol(needs ? "bell.fill" : "pin.fill"); icon.contentTintColor = needs ? .systemOrange : .secondaryLabelColor
            title.stringValue = needs ? String(localized: "Needs You") : String(localized: "Pinned")   // the kind stays English, the title is shown translated
            count.stringValue = "\(node.children.count)"; toolTip = nil
        case .needs(let sid):
            guard let s = m.session(sid) else { return }
            icon.image = app.catalog.icon(s.agent, size: 16); icon.contentTintColor = .secondaryLabelColor
            title.stringValue = app.catalog.displayName(s)
            title.font = .ui(13, weight: Self.isNews(s) ? .semibold : .regular)
            let w = m.worktree(s.worktreeId)
            count.stringValue = [w?.displayName, m.repo(w?.repoId)?.name].compactMap { $0 }.joined(separator: " · ")
            mark.status = s.endedWithError ? .error : Self.shownStatus(s); mark.unread = s.unread; mark.compacting = s.summary.hasPrefix("Compacting")
            mark.progress = s.progress.map { Double($0) / 100 }
            trailing.stringValue = shortAgo(s.statusAt ?? s.createdAt)
            showState(s)
        case .workspace(let id):
            guard let w = m.worktree(id) else { return }
            let agents = live(id)
            title.stringValue = w.displayName
            title.font = .ui(13, weight: agents.contains(where: Self.isNews) ? .semibold : .medium)   // a heading for its agents
            let paused = !agents.isEmpty && agents.allSatisfy { $0.status == .hibernated }
            title.textColor = paused ? .secondaryLabelColor : .labelColor
            // Expanded, its agents show their own state; collapsed, the workspace sums them up.
            let collapsed = owner?.isCollapsed(node) ?? false
            let top = AgentStatus.mostUrgent(agents.map(Self.shownStatus))
            let lead = agents.filter { Self.shownStatus($0) == top }.max { ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt) }
            mark.status = collapsed ? top : nil; mark.unread = agents.contains { Self.shownStatus($0) == top && $0.unread }
            trailing.stringValue = collapsed ? shortAgo(lead.map { $0.statusAt ?? $0.createdAt }) : ""
            toolTip = nil   // the hover card shows the workspace in full
        case .agent(let sid):
            guard let s = m.session(sid) else { return }
            icon.image = app.catalog.icon(s.agent, size: 16); icon.contentTintColor = .secondaryLabelColor
            icon.alphaValue = s.status == .hibernated ? 0.45 : 1
            title.stringValue = app.catalog.displayName(s)
            title.font = .ui(13, weight: Self.isNews(s) ? .semibold : .regular)
            mark.status = Self.shownStatus(s); mark.unread = s.unread; mark.compacting = s.summary.hasPrefix("Compacting")
            mark.progress = s.progress.map { Double($0) / 100 }
            trailing.stringValue = s.status == .idle ? "" : shortAgo(s.statusAt ?? s.createdAt)
            showState(s)
        }
    }

    /// One line, as Mail lists mailboxes: an agent asking for you or done unseen is bold (isNews) and its mark says which;
    /// the colour stays on the mark (orange text on a light sidebar is 2:1). What it asks or did is on the hover card.
    private func showState(_ s: Session) {
        title.textColor = s.status == .hibernated ? .secondaryLabelColor : .labelColor
        trailing.textColor = .secondaryLabelColor
        toolTip = nil
    }

    /// Asks for you, failed, or finished and not looked at yet.
    static func wantsYou(_ s: Session) -> Bool {
        let st = shownStatus(s)
        return s.agent != "shell" && (st == .waiting || st == .error || (st == .done && s.unread))
    }

    /// A paused agent's row is dimmed, but what it finished and you haven't read keeps its bright mark.
    static func shownStatus(_ s: Session) -> AgentStatus { s.status == .hibernated && s.unread ? .done : s.markStatus }

    /// Something to look at: finished or asking, and not opened since (bold, like unread mail).
    static func isNews(_ s: Session) -> Bool { s.unread && [.done, .waiting, .error].contains(shownStatus(s)) }

    func beginEditing(delegate: NSTextFieldDelegate) {
        title.isEditable = true; title.isSelectable = true; title.drawsBackground = true; title.delegate = delegate
        window?.makeFirstResponder(title)
        title.currentEditor()?.selectAll(nil)
    }
}

/// Levels line up as Mail nests mailboxes: a workspace's name under its project's (the cell's 2 pt, icon 16, gap 6),
/// an agent's icon under the workspace's name, the chevron on the project icon's axis.
final class SidebarOutline: NSOutlineView {
    static let lead: CGFloat = 14, step: CGFloat = 22
    /// Room over and under a row's content, where its project's card opens and closes (SidebarRowView.group).
    var pads: (Int) -> (top: CGFloat, bottom: CGFloat) = { _ in (0, 0) }
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var r = padded(super.frameOfOutlineCell(atRow: row), row)
        r.origin.x = Self.lead + 2 + 8 - r.width / 2
        return r
    }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var r = padded(super.frameOfCell(atColumn: column, row: row), row)
        let x = Self.lead + (level(forRow: row) > 0 ? Self.step : 0)
        r.size.width = r.maxX - x; r.origin.x = x
        return r
    }
    private func padded(_ r: NSRect, _ row: Int) -> NSRect {
        let p = pads(row)
        return NSRect(x: r.minX, y: r.minY + p.top, width: r.width, height: r.height - p.top - p.bottom)
    }
}

/// Like Safari's tab groups: each project sits on a quiet card, the workspace on screen and its agents on a stronger
/// one inside it, and the row you're on is a raised pill (no accent colour, so the text keeps its colours).
@MainActor
final class SidebarRowView: NSTableRowView {
    /// Where this row is in the workspace's card: nil outside it.
    var card: (first: Bool, last: Bool)? { didSet { if card?.first != oldValue?.first || card?.last != oldValue?.last { needsDisplay = true } } }
    /// Where this row is in its project's card; the outline leaves 4 pt over a first row and 8 under a last (SidebarOutline.pads).
    var group: (first: Bool, last: Bool)? { didSet { if group?.first != oldValue?.first || group?.last != oldValue?.last { needsDisplay = true } } }

    static let groupFill = NSColor.labelColor.withAlphaComponent(0.045)
    static let cardFill = NSColor.labelColor.withAlphaComponent(0.075)
    static let pillFill = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.black.withAlphaComponent(0.32) : .white }

    override func drawBackground(in r: NSRect) {
        // Each card is 6 pt in from the one around it, the pill 4 pt inside its card (corners 12, 10, 6).
        // Rows in the middle extend past their bounds, so only a card's ends are rounded. Flipped: y grows down.
        if let group {
            fill(bounds.insetBy(dx: 6, dy: 0), first: group.first, top: 4, last: group.last, bottom: 4, radius: 12, Self.groupFill)
        }
        let side: CGFloat = group == nil ? 6 : 12
        if let card {
            fill(bounds.insetBy(dx: side, dy: 0), first: card.first, top: 0, last: card.last, bottom: group?.last == true ? 8 : 0, radius: 10, Self.cardFill)
        }
        guard isSelected else { return }   // the outline draws no selection of its own (selectionHighlightStyle .none)
        var pill = bounds.insetBy(dx: (card == nil ? 6 : side) + 4, dy: 3)
        if card?.first == true { pill.origin.y += 1; pill.size.height -= 1 }
        if card?.last == true { pill.size.height -= 1 }
        if group?.last == true { pill.size.height -= 8 }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.12); shadow.shadowBlurRadius = 2; shadow.shadowOffset = .init(width: 0, height: -0.5)
        shadow.set()
        Self.pillFill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    // swiftlint:disable:next function_parameter_count
    private func fill(_ r: NSRect, first: Bool, top: CGFloat, last: Bool, bottom: CGFloat, radius: CGFloat, _ color: NSColor) {
        var r = r
        if first { r.origin.y += top; r.size.height -= top } else { r.origin.y -= 12; r.size.height += 12 }
        r.size.height += last ? -bottom : 12
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
    /// The outline sizes a row's cell once; when the row's height changes later (a project's last row gains or loses the
    /// card's foot) the cell would only stretch with it, its text off the chevron. Put it where the outline says.
    override func resizeSubviews(withOldSize old: NSSize) {
        super.resizeSubviews(withOldSize: old)
        guard let o = superview as? NSOutlineView, case let row = o.row(for: self), row >= 0, let cell = subviews.first(where: { $0 is NSTableCellView }) else { return }
        let f = o.frameOfCell(atColumn: 0, row: row)   // only its height: mid-update a project's row comes back narrower
        cell.frame = NSRect(x: cell.frame.minX, y: f.minY - o.rect(ofRow: row).minY, width: cell.frame.width, height: f.height)
    }
    override var isSelected: Bool { didSet { if isSelected != oldValue { needsDisplay = true } } }
    /// In the sidebar's vibrant material a dark fill would come out lighter; the card and pill are drawn as they are.
    override var allowsVibrancy: Bool { false }
    /// The pill isn't the accent colour, so the cell draws as unselected (white text on it would vanish).
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
