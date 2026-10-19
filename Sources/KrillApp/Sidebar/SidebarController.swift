import AppKit
import SwiftUI
import Core

/// Projects → workspaces → agents in a source-list outline (like Finder and Xcode).
/// Status changes update the visible cells in place; the outline reloads only when the tree's shape changes.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    final class Node: NSObject {
        enum Kind { case project(String), workspace(String), agent(String) }
        let kind: Kind
        var children: [Node] = []
        init(_ k: Kind) { kind = k }
        var key: String {
            switch kind {
            case .project(let id): "p:" + id
            case .workspace(let id): "w:" + id
            case .agent(let id): "a:" + id
            }
        }
    }

    private let outline = NSOutlineView()
    private var roots: [Node] = []
    private var shape: [String] = []
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "sidebar.collapsed") ?? [])
    private var syncing = false
    private var renaming: String?
    private let empty = NSStackView()
    private let search = NSSearchField()
    private var query = ""

    override func loadView() {
        let col = NSTableColumn(identifier: .init("main")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil; outline.style = .sourceList; outline.rowSizeStyle = .custom
        outline.floatsGroupRows = false; outline.indentationPerLevel = 14
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL])   // a folder from Finder becomes a project
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        // When the list gets shorter (the limits below load), the selected workspace stays in view.
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOpenInView() }
        }

        let footer = NSHostingView(rootView: SidebarFooterView())
        footer.sizingOptions = [.intrinsicContentSize]
        let v = NSView()
        search.placeholderString = "Workspace or agent"; search.delegate = self; search.controlSize = .small
        search.sendsSearchStringImmediately = true; search.target = self; search.action = #selector(searchChanged)
        // In the title bar, by the traffic lights: over the projects it adds to, where people look for it.
        let add = NSButton.titlebar("folder.badge.plus", "Add Project", tip: "Add a project folder (⌘O)")
        add.target = NSApp.delegate; add.action = #selector(AppDelegate.addProject)
        for x in [add, search, scroll, footer, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            add.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10), add.centerYAnchor.constraint(equalTo: v.topAnchor, constant: TabStrip.height / 2),
            search.topAnchor.constraint(equalTo: v.topAnchor, constant: TabStrip.height + 6),
            search.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10), search.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: v.leadingAnchor), footer.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.centerYAnchor.constraint(equalTo: v.centerYAnchor, constant: -40),
            empty.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -32)
        ])
        buildEmpty()
        view = v
        track { AppModel.shared.repos } changed: { [weak self] _ in self?.refresh() }
        track { AppModel.shared.worktrees } changed: { [weak self] _ in self?.refresh() }
        track { AppModel.shared.sessions } changed: { [weak self] _ in self?.refresh() }
        track { Workbench.shared.workspaceId } changed: { [weak self] _ in self?.syncSelection() }
        // "now" becomes "1m": the times on the right move on their own.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateVisibleCells() } }
    }

    private func updateVisibleCells() {
        for row in 0..<outline.numberOfRows { (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.update() }
    }

    private func buildEmpty() {
        let icon = NSImageView(image: .symbol("folder.badge.plus")); icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let t = NSTextField(labelWithString: "No Projects"); t.font = .systemFont(ofSize: 13, weight: .semibold)
        let d = NSTextField(wrappingLabelWithString: "Add a git repository to start."); d.textColor = .secondaryLabelColor; d.alignment = .center
        let b = ClosureButton(title: "Add Project…") { Workbench.addProject() }; b.bezelStyle = .push
        [icon, t, d, b].forEach { empty.addArrangedSubview($0) }
        empty.orientation = .vertical; empty.spacing = 8
    }

    // MARK: model → tree

    private func build() -> [Node] {
        let m = AppModel.shared
        let q = query.lowercased()
        func hit(_ text: String...) -> Bool { q.isEmpty || text.contains { $0.lowercased().contains(q) } }
        return m.repos.compactMap { r in
            let p = Node(.project(r.id))
            p.children = m.workspaces(of: r).compactMap { w in
                // Agents only: terminals are tabs, not something to keep an eye on.
                let agents = m.sessions.filter { $0.worktreeId == w.id && $0.status != .exited && $0.agent != "shell" }
                let whole = hit(w.displayName, w.branch, r.name)
                let kept = whole ? agents : agents.filter { hit($0.title, $0.agent ?? "", $0.summary, $0.status.label) }   // "needs", "working", "done" act as filters
                guard whole || !kept.isEmpty else { return nil }
                let n = Node(.workspace(w.id))
                n.children = kept.map { Node(.agent($0.id)) }
                return n
            }
            return p.children.isEmpty && !q.isEmpty ? nil : p
        }
    }

    @objc private func searchChanged() { query = search.stringValue.trimmingCharacters(in: .whitespaces); refresh() }

    /// Same shape → refresh the visible cells; new shape → reload, keeping expansion and selection.
    private func refresh() {
        let next = build()
        func flat(_ ns: [Node]) -> [String] { ns.flatMap { [$0.key] + flat($0.children) } }
        let nextShape = flat(next)
        empty.isHidden = !next.isEmpty || !query.isEmpty
        search.isHidden = AppModel.shared.repos.isEmpty
        if nextShape == shape { updateVisibleCells(); return }
        roots = next; shape = nextShape
        syncing = true
        outline.reloadData()
        for p in roots { outline.expandItem(p); for w in p.children where !collapsed.contains(w.key) { outline.expandItem(w) } }
        syncing = false
        updateVisibleCells()   // cells were made before their rows expanded
        syncSelection()
    }

    private func node(_ key: String) -> Node? {
        func find(_ ns: [Node]) -> Node? { for n in ns { if n.key == key { return n }; if let f = find(n.children) { return f } }; return nil }
        return find(roots)
    }

    private func syncSelection() {
        guard let id = Workbench.shared.workspaceId, let n = node("w:" + id) else { return }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        if outline.selectedRow != row, !isAgent(outline.item(atRow: outline.selectedRow), in: id) {
            syncing = true; outline.selectRowIndexes([row], byExtendingSelection: false); syncing = false
        }
        keepOpenInView()
    }

    /// The workspace on screen stays in view with its agents under it (they can show up after it was selected).
    private func keepOpenInView() {
        guard let id = Workbench.shared.workspaceId, let n = node("w:" + id) else { return }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        if let last = n.children.last, outline.isItemExpanded(n) { outline.scrollRowToVisible(outline.row(forItem: last)) }
        outline.scrollRowToVisible(row)
    }
    func isCollapsed(_ n: Node) -> Bool { !n.children.isEmpty && !outline.isItemExpanded(n) }
    private func isAgent(_ item: Any?, in workspace: String) -> Bool {
        guard let n = item as? Node, case .agent(let sid) = n.kind else { return false }
        return AppModel.shared.session(sid)?.worktreeId == workspace
    }

    // MARK: data source / delegate

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[i] ?? roots[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { if case .project? = (item as? Node)?.kind { true } else { false } }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { if case .project? = (item as? Node)?.kind { false } else { true } }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { if case .project? = (item as? Node)?.kind { false } else { true } }
    // One line per row, like Mail's mailbox list; section headers a little taller for air above them.
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if case .project? = (item as? Node)?.kind { return 28 }
        return 26
    }

    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let cell = SidebarCell(node: n, owner: self)
        cell.update()
        return cell
    }

    func outlineViewItemDidCollapse(_ n: Notification) { remember(n, collapsed: true) }
    func outlineViewItemDidExpand(_ n: Notification) { remember(n, collapsed: false) }
    private func remember(_ n: Notification, collapsed c: Bool) {
        guard !syncing, let node = n.userInfo?["NSObject"] as? Node, case .workspace = node.kind else { return }
        if c { collapsed.insert(node.key) } else { collapsed.remove(node.key) }
        UserDefaults.standard.set(Array(collapsed), forKey: "sidebar.collapsed")
        refreshCell(node.key)   // collapsed, the workspace shows its agents' state itself
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !syncing, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        switch node.kind {
        case .workspace(let id): Workbench.show(workspace: id)
        case .agent(let id): Workbench.focus(session: id)
        case .project: break
        }
    }

    // MARK: folders dropped from Finder

    private static func folders(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.path)
    }
    func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard !Self.folders(info).isEmpty else { return [] }
        o.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)   // the whole list, not a row
        return .copy
    }
    func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let folders = Self.folders(info)
        folders.forEach(Workbench.addProject(path:))
        return !folders.isEmpty
    }

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node, case .workspace(let id) = node.kind else { return }
        startRename(id)
    }

    // MARK: actions

    func newWorkspace(_ repo: String) { Workbench.newWorkspace(repo: repo) }
    private func refreshCell(_ key: String) {
        guard let n = node(key) else { return }
        let row = outline.row(forItem: n)
        if row >= 0 { (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.update() }
    }

    /// Inline rename, like Finder.
    func startRename(_ workspace: String) {
        guard let n = node("w:" + workspace) else { return }
        let row = outline.row(forItem: n)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell else { return }
        renaming = workspace
        cell.beginEditing(delegate: self)
    }
    func controlTextDidEndEditing(_ n: Notification) {
        guard let id = renaming, let field = n.object as? NSTextField else { return }
        renaming = nil
        field.isEditable = false; field.drawsBackground = false
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != AppModel.shared.worktree(id)?.displayName {
            Task { await AppModel.shared.call("worktree.note", .obj(["id": .string(id), "note": .string(name)])) }
        } else { refreshCell("w:" + id) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
        let m = AppModel.shared
        switch n.kind {
        case .project(let id):
            guard let r = m.repo(id) else { return }
            menu.add("New Workspace") { [weak self] in self?.newWorkspace(id) }
            menu.add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
            menu.addItem(.separator())
            menu.add("Remove Project…") { WorkspaceActions.removeProject(r) }
        case .workspace(let id):
            guard let w = m.worktree(id) else { return }
            menu.add("Rename") { [weak self] in self?.startRename(id) }
            menu.add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
            menu.add("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(w.path, forType: .string) }
            WorkspaceActions.addOpenIn(to: menu, path: w.path)
            menu.addItem(.separator())
            if w.path == m.repo(w.repoId)?.path {
                // A desk: closing it ends its agents; the project's folder is untouched.
                let item = menu.add("Close Workspace") { WorkspaceActions.close(w) }
                item.isEnabled = m.worktrees.filter { $0.repoId == w.repoId && $0.path == w.path }.count > 1
            } else {
                menu.add("Archive") { Task { await AppModel.shared.call("worktree.archive", .obj(["id": .string(id)])) } }
                menu.add("Delete Workspace & Branch…") { WorkspaceActions.delete(w) }
            }
        case .agent(let sid):
            menu.add("Show") { Workbench.focus(session: sid) }
            menu.add("Rename…") { AgentActions.rename(sid) }
            menu.add("Restart") { AgentActions.restart(sid) }
            menu.addItem(.separator())
            menu.add("Copy Context") { AgentActions.copyContext(sid) }
            if m.session(sid)?.unread == false { menu.add("Mark as Unread") { Task { await AppModel.shared.call("session.markUnread", .obj(["id": .string(sid)])) } } }
            menu.addItem(.separator())
            menu.add("Stop") { Task { await AppModel.shared.call("session.kill", .obj(["id": .string(sid)])) } }
        }
    }
}

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

    init(node: SidebarController.Node, owner: SidebarController) {
        self.node = node; self.owner = owner
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        trailing.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); trailing.textColor = .secondaryLabelColor
        textField = title
        switch node.kind {
        case .project(let id):
            title.font = .systemFont(ofSize: 11, weight: .semibold); title.textColor = .secondaryLabelColor
            count.font = .systemFont(ofSize: 11); count.textColor = .tertiaryLabelColor
            trailing.font = .systemFont(ofSize: 11, weight: .medium); trailing.textColor = .systemOrange
            let b = ClosureButton(title: "") { [weak owner] in owner?.newWorkspace(id) }
            b.image = .symbol("plus", "New Workspace"); b.isBordered = false; b.contentTintColor = .secondaryLabelColor
            b.toolTip = "New workspace (⌘N)"; b.isHidden = true; add = b   // on hover, like Finder's sidebar
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
            layout(row: [title, count, NSView(), trailing, b])
        case .workspace:
            title.font = .systemFont(ofSize: 13)
            layout(row: [title, NSView(), trailing, mark])
        case .agent:
            title.font = .systemFont(ofSize: 13)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true; icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            layout(row: [icon, title, NSView(), trailing, mark])
        }
        for v in [title, count] { v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { add?.isHidden = false }
    override func mouseExited(with e: NSEvent) { add?.isHidden = true }

    private func layout(row: [NSView]) {
        let r = NSStackView(views: row); r.spacing = 6; r.alignment = .centerY
        r.translatesAutoresizingMaskIntoConstraints = false; addSubview(r)
        NSLayoutConstraint.activate([r.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), r.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                                     r.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    func update() {
        let m = AppModel.shared
        func live(_ wid: String) -> [Session] { m.sessions.filter { $0.worktreeId == wid && $0.status != .exited && $0.agent != "shell" } }
        switch node.kind {
        case .project(let id):
            let r = m.repo(id)
            title.stringValue = r?.name ?? ""; toolTip = r?.path
            count.stringValue = node.children.isEmpty ? "" : "\(node.children.count)"
            let waiting = m.worktrees.filter { $0.repoId == id }.flatMap { live($0.id) }.filter { $0.status == .waiting }.count
            trailing.stringValue = waiting == 0 ? "" : waiting == 1 ? "1 needs you" : "\(waiting) need you"
        case .workspace(let id):
            guard let w = m.worktree(id) else { return }
            let agents = live(id)
            title.stringValue = w.displayName
            title.font = .systemFont(ofSize: 13, weight: agents.contains(where: Self.isNews) ? .semibold : .regular)
            let paused = !agents.isEmpty && agents.allSatisfy { $0.status == .hibernated }
            title.textColor = paused ? .tertiaryLabelColor : .labelColor
            // Expanded, its agents show their own state; collapsed, the workspace sums them up.
            let collapsed = owner?.isCollapsed(node) ?? false
            let top = AgentStatus.mostUrgent(agents.map(\.status))
            let lead = agents.filter { $0.status == top }.max { ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt) }
            mark.status = collapsed ? top : nil; mark.unread = agents.contains { $0.status == top && $0.unread }
            trailing.stringValue = collapsed ? shortAgo(lead.map { $0.statusAt ?? $0.createdAt }) : ""
            let isMain = w.path == m.repo(w.repoId)?.path
            toolTip = ([w.path + (isMain ? "" : "\nBranch \(w.branch)")]
                       + agents.map { "\(AgentCatalog.displayName($0)) — \($0.status.words)" + ($0.summary.isEmpty ? "" : ": \($0.summary)") })
                .joined(separator: "\n")
        case .agent(let sid):
            guard let s = m.session(sid) else { return }
            icon.image = AgentCatalog.icon(s.agent, size: 16); icon.contentTintColor = .secondaryLabelColor
            icon.alphaValue = s.status == .hibernated ? 0.45 : 1
            title.stringValue = AgentCatalog.displayName(s)
            title.font = .systemFont(ofSize: 13, weight: Self.isNews(s) ? .semibold : .regular)
            title.textColor = s.status == .hibernated ? .tertiaryLabelColor : .labelColor
            mark.status = s.status; mark.unread = s.unread
            trailing.stringValue = s.status == .idle ? "" : shortAgo(s.statusAt ?? s.createdAt)
            toolTip = "\(AgentCatalog.name(s.agent)) — \(s.status.words)" + (s.summary.isEmpty ? "" : "\n\(s.summary)")
        }
    }

    /// Something to look at: finished or asking, and not opened since (bold, like unread mail).
    static func isNews(_ s: Session) -> Bool { s.unread && (s.status == .done || s.status == .waiting) }

    func beginEditing(delegate: NSTextFieldDelegate) {
        title.isEditable = true; title.isSelectable = true; title.drawsBackground = true; title.delegate = delegate
        window?.makeFirstResponder(title)
        title.currentEditor()?.selectAll(nil)
    }
}

/// Bottom of the sidebar: agent limits, when any agent reports them. (Add Project is in the title bar above.)
struct SidebarFooterView: View {
    var body: some View { UsageView() }
}
