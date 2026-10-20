import AppKit
import SwiftUI
import Core
import GitKit

/// One row; `update()` re-reads the model, so status changes don't rebuild the outline.
@MainActor
final class SidebarCell: NSTableCellView {
    private let node: SidebarController.Node
    private weak var owner: SidebarController?
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
        self.node = node; self.owner = owner
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        trailing.font = .uiDigits(11, weight: .regular); trailing.textColor = .secondaryLabelColor
        textField = title
        switch node.kind {
        case .project(let id):
            // A name, not a section label: what's under it is the project's. On the right only what needs doing.
            // Not the cell's textField: the source list would restyle it as a grey group heading.
            textField = nil; title.font = .ui(13, weight: .semibold); title.textColor = .labelColor
            trailing.font = .ui(11, weight: .semibold); trailing.textColor = .systemOrange
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

    override func mouseEntered(with e: NSEvent) { add?.isHidden = false }
    override func mouseExited(with e: NSEvent) { add?.isHidden = true }

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
        case .project(let id): RowBadges.folder(project: id)
        case .workspace(let id): RowBadges.folder(workspace: id)
        case .agent, .section, .needs: nil
        }
    }
    @objc private func openChanges() { if let w = folder { Workbench.open(DiffTab.uri(w.id), workspace: w.id) } }
    @objc private func openPR() { if let w = folder, let u = RowBadges.shared.prs[w.id]?["url"]?.string { Workbench.open(u, workspace: w.id) } }

    /// The stack shows a badge only when there's something to say, and drops it first when the row is narrow.
    private func updateBadges() {
        let w = folder
        if let w { RowBadges.shared.refresh(w.id) }
        let c = w.flatMap { RowBadges.changes(RowBadges.shared.stats[$0.id]) }
        let p = w.flatMap { RowBadges.pr(RowBadges.shared.prs[$0.id]) }
        if let c { changes.attributedTitle = c; changes.toolTip = String(localized: "Not committed yet — click for the changes") }
        if let p { pr.attributedTitle = p.0; pr.toolTip = p.1 }
        guard let r = changes.superview as? NSStackView else { return }
        r.setVisibilityPriority(c == nil ? .notVisible : .detachOnlyIfNecessary, for: changes)
        r.setVisibilityPriority(p == nil ? .notVisible : .detachOnlyIfNecessary, for: pr)
    }

    func update() {
        updateBadges()
        let m = AppModel.shared
        func live(_ wid: String) -> [Session] { m.sessions.filter { $0.worktreeId == wid && $0.status != .exited && $0.agent != "shell" } }
        switch node.kind {
        case .project(let id):
            let r = m.repo(id)
            let missing = r.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
            icon.image = missing ? .symbol("questionmark.folder") : r.map { ProjectIcon.image(for: $0.path) }
            icon.contentTintColor = .secondaryLabelColor
            title.stringValue = r?.name ?? ""
            toolTip = missing ? String(localized: "\(r?.path ?? "") isn't there anymore. Right-click › Locate… if it moved.") : r?.path
            let waiting = m.worktrees.filter { $0.repoId == id }.flatMap { live($0.id) }.filter(Self.wantsYou).count
            trailing.stringValue = missing ? String(localized: "Folder missing") : waiting == 0 ? "" : waiting == 1 ? String(localized: "1 needs you") : String(localized: "\(waiting) need you")
        case .section(let name):
            let needs = name == "Needs You"
            icon.image = .symbol(needs ? "bell.fill" : "pin.fill"); icon.contentTintColor = needs ? .systemOrange : .secondaryLabelColor
            title.stringValue = needs ? String(localized: "Needs You") : String(localized: "Pinned")   // the kind stays English, the title is shown translated
            count.stringValue = "\(node.children.count)"; toolTip = nil
        case .needs(let sid):
            guard let s = m.session(sid) else { return }
            icon.image = AgentCatalog.icon(s.agent, size: 16); icon.contentTintColor = .secondaryLabelColor
            title.stringValue = AgentCatalog.displayName(s)
            title.font = .ui(13, weight: Self.isNews(s) ? .semibold : .regular)
            let w = m.worktree(s.worktreeId)
            count.stringValue = [w?.displayName, m.repo(w?.repoId)?.name].compactMap { $0 }.joined(separator: " · ")
            mark.status = s.endedWithError ? .error : s.status; mark.unread = s.unread; mark.compacting = s.summary.hasPrefix("Compacting")
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
            icon.image = AgentCatalog.icon(s.agent, size: 16); icon.contentTintColor = .secondaryLabelColor
            icon.alphaValue = s.status == .hibernated ? 0.45 : 1
            title.stringValue = AgentCatalog.displayName(s)
            title.font = .ui(13, weight: Self.isNews(s) ? .semibold : .regular)
            mark.status = Self.shownStatus(s); mark.unread = s.unread; mark.compacting = s.summary.hasPrefix("Compacting")
            trailing.stringValue = s.status == .idle ? "" : shortAgo(s.statusAt ?? s.createdAt)
            showState(s)
        }
    }

    /// One line, as Mail lists mailboxes: an agent asking for you has its name and time in orange (red when it failed),
    /// one that finished unseen is bold (isNews); what it asks or did is on the hover card.
    private func showState(_ s: Session) {
        let st = Self.shownStatus(s)
        let tint: NSColor? = st == .waiting ? .systemOrange : st == .error || s.endedWithError ? .systemRed : nil
        title.textColor = tint ?? (s.status == .hibernated ? .secondaryLabelColor : .labelColor)
        trailing.textColor = tint ?? .secondaryLabelColor
        toolTip = nil
    }

    /// Asks for you, failed, or finished and not looked at yet.
    static func wantsYou(_ s: Session) -> Bool {
        let st = shownStatus(s)
        return s.agent != "shell" && (st == .waiting || st == .error || (st == .done && s.unread))
    }

    /// A paused agent's row is dimmed, but what it finished and you haven't read keeps its bright mark.
    static func shownStatus(_ s: Session) -> AgentStatus { s.status == .hibernated && s.unread ? .done : s.status }

    /// Something to look at: finished or asking, and not opened since (bold, like unread mail).
    static func isNews(_ s: Session) -> Bool { s.unread && (s.status == .done || s.status == .waiting || s.status == .error) }

    func beginEditing(delegate: NSTextFieldDelegate) {
        title.isEditable = true; title.isSelectable = true; title.drawsBackground = true; title.delegate = delegate
        window?.makeFirstResponder(title)
        title.currentEditor()?.selectAll(nil)
    }
}

/// Bottom of the sidebar: agent limits, when any agent reports them. (Add Project is beside the search above.)
struct SidebarFooterView: View {
    var body: some View { UsageView() }
}
