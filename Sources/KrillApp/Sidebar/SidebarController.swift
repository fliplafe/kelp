import AppKit
import SwiftUI
import Core

/// Projects → workspaces → agents in a source-list outline (like Finder and Xcode).
/// Status changes update the visible cells in place; the outline reloads only when the tree's shape changes.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
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

    override func loadView() {
        let col = NSTableColumn(identifier: .init("main")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil; outline.style = .sourceList; outline.rowSizeStyle = .custom
        outline.floatsGroupRows = false; outline.indentationPerLevel = 14
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.doubleAction = #selector(doubleClicked)
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false

        let footer = NSHostingView(rootView: SidebarFooterView())
        footer.sizingOptions = [.intrinsicContentSize]
        let v = NSView()
        for x in [scroll, footer, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor), scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
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
        return m.repos.map { r in
            let p = Node(.project(r.id))
            p.children = m.workspaces(of: r).map { w in
                let n = Node(.workspace(w.id))
                // Agents only: terminals are tabs, not something to keep an eye on.
                n.children = m.sessions.filter { $0.worktreeId == w.id && $0.status != .exited && $0.agent != "shell" }.map { Node(.agent($0.id)) }
                return n
            }
            return p
        }
    }

    /// Same shape → refresh the visible cells; new shape → reload, keeping expansion and selection.
    private func refresh() {
        let next = build()
        func flat(_ ns: [Node]) -> [String] { ns.flatMap { [$0.key] + flat($0.children) } }
        let nextShape = flat(next)
        empty.isHidden = !next.isEmpty
        if nextShape == shape {
            for row in 0..<outline.numberOfRows { (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.update() }
            return
        }
        roots = next; shape = nextShape
        syncing = true
        outline.reloadData()
        for p in roots { outline.expandItem(p); for w in p.children where !collapsed.contains(w.key) { outline.expandItem(w) } }
        syncing = false
        syncSelection()
    }

    private func node(_ key: String) -> Node? {
        func find(_ ns: [Node]) -> Node? { for n in ns { if n.key == key { return n }; if let f = find(n.children) { return f } }; return nil }
        return find(roots)
    }

    private func syncSelection() {
        guard let id = Workbench.shared.workspaceId, let n = node("w:" + id) else { return }
        let row = outline.row(forItem: n)
        guard row >= 0, outline.selectedRow != row, !(outline.item(atRow: outline.selectedRow) is Node && isAgent(outline.item(atRow: outline.selectedRow), in: id)) else { return }
        syncing = true; outline.selectRowIndexes([row], byExtendingSelection: false); syncing = false
    }
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
    // Source-list metrics (Finder, Mail): one line per row.
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as? Node)?.kind {
        case .project?: 26
        case .workspace?: 28
        default: 24
        }
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
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !syncing, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        switch node.kind {
        case .workspace(let id): Workbench.show(workspace: id)
        case .agent(let id): Workbench.focus(session: id)
        case .project: break
        }
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
    private let mark = StatusMark(size: 14)
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let badgeMark = StatusMark(size: 12)
    private var add: NSButton?

    init(node: SidebarController.Node, owner: SidebarController) {
        self.node = node; self.owner = owner
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        badge.font = .systemFont(ofSize: 11, weight: .semibold); badge.textColor = .systemOrange
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        textField = title; imageView = icon
        switch node.kind {
        case .project(let id):
            title.font = .systemFont(ofSize: 11, weight: .semibold); title.textColor = .secondaryLabelColor
            let b = ClosureButton(title: "") { [weak owner] in owner?.newWorkspace(id) }
            b.image = .symbol("plus", "New Workspace"); b.isBordered = false; b.contentTintColor = .secondaryLabelColor
            b.toolTip = "New workspace (⌘N)"; add = b
            layout(row: [title, NSView(), b])
        case .workspace:
            title.font = .systemFont(ofSize: 13)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            layout(row: [icon, title, NSView(), badge, badgeMark])
        case .agent:
            title.font = .systemFont(ofSize: 13)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            layout(row: [mark, title, NSView()])
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout(row: [NSView]) {
        let r = NSStackView(views: row); r.spacing = 6; r.alignment = .centerY
        r.translatesAutoresizingMaskIntoConstraints = false; addSubview(r)
        NSLayoutConstraint.activate([r.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), r.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                                     r.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    func update() {
        let m = AppModel.shared
        switch node.kind {
        case .project(let id):
            let r = m.repo(id)
            title.stringValue = r?.name ?? ""; toolTip = r?.path
        case .workspace(let id):
            guard let w = m.worktree(id) else { return }
            let isMain = w.path == m.repo(w.repoId)?.path
            let agents = m.sessions.filter { $0.worktreeId == id && $0.status != .exited && $0.agent != "shell" }
            // A desk in the project folder; older workspaces on their own branch keep the branch icon.
            icon.image = .symbol(isMain ? "rectangle.split.2x1" : "arrow.triangle.branch"); icon.contentTintColor = .controlAccentColor
            title.stringValue = w.displayName
            // Bold = something new to look at (like unread mail); a paused agent has nothing new.
            title.font = .systemFont(ofSize: 13, weight: agents.contains { $0.unread && $0.status != .hibernated } ? .semibold : .regular)
            let waiting = agents.filter { $0.status == .waiting }.count
            badge.stringValue = waiting > 1 ? "\(waiting)" : ""
            badgeMark.status = waiting > 0 ? .waiting : agents.contains { $0.status == .working } ? .working
                : agents.contains { $0.status == .done && $0.unread } ? .done : nil
            // The branch and folder are one hover away (and in the title bar for the open workspace).
            toolTip = w.path + (isMain ? "" : "\nBranch \(w.branch)")
        case .agent(let sid):
            guard let s = m.session(sid) else { return }
            mark.status = s.agent == "shell" ? nil : s.status
            if s.agent == "shell" { icon.image = .symbol("terminal") }
            title.stringValue = s.title.isEmpty ? AgentCatalog.name(s.agent) : s.title
            title.font = .systemFont(ofSize: 13, weight: s.unread && s.status != .hibernated ? .semibold : .regular)
            title.textColor = s.status == .hibernated ? .secondaryLabelColor : .labelColor
            toolTip = "\(AgentCatalog.name(s.agent)) · \(s.status.words)" + (s.summary.isEmpty ? "" : "\n\(s.summary)")
        }
    }

    func beginEditing(delegate: NSTextFieldDelegate) {
        title.isEditable = true; title.isSelectable = true; title.drawsBackground = true; title.delegate = delegate
        window?.makeFirstResponder(title)
        title.currentEditor()?.selectAll(nil)
    }
}

/// Bottom of the sidebar: agent limits, then "Add Project".
struct SidebarFooterView: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            UsageView().padding(.horizontal, 12).padding(.top, 8)
            HStack {
                Button { Workbench.addProject() } label: { Label("Add Project", systemImage: "plus") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}
