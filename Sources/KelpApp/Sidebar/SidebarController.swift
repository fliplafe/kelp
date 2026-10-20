import AppKit
import SwiftUI
import Core
import GitKit
import WorkbenchKit

/// Projects → workspaces → agents in a source-list outline (like Finder and Xcode).
/// Status changes update the visible cells in place; the outline reloads only when the tree's shape changes.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    final class Node: NSObject {
        /// `section`: "Needs You" / "Pinned" over the projects; `needs`: an agent listed there (it's also under its workspace).
        enum Kind { case project(String), workspace(String), agent(String), section(String), needs(String) }
        let kind: Kind
        var children: [Node] = []
        init(_ k: Kind) { kind = k }
        var key: String {
            switch kind {
            case .project(let id): "p:" + id
            case .workspace(let id): "w:" + id
            case .agent(let id): "a:" + id
            case .section(let s): "s:" + s
            case .needs(let id): "n:" + id
            }
        }
        /// What a dragged row reorders: a project's or a workspace's id.
        var id: String? {
            switch kind {
            case .project(let id), .workspace(let id): id
            default: nil
            }
        }
    }

    private let outline = NSOutlineView()
    private var roots: [Node] = []
    private var shape: [String] = []
    private var collapsed: Set<String> {
        get { Set(UIState.strings("sidebar.collapsed")) }
        set { UIState["sidebar.collapsed"] = try? .from(newValue.sorted()) }
    }
    private var syncing = false
    private var renaming: String?
    private let empty = NSStackView()
    private let search = NSSearchField()
    private var query = ""
    private let card = HoverCard()
    /// The search field's menu (its magnifier): which workspaces to show. The one on screen always stays.
    enum Filter: String, CaseIterable {
        case all = "All Workspaces", working = "Working", needsYou = "Needs You", withPR = "With a Pull Request"
        var tree: SidebarFilter {
            switch self {
            case .all: .all
            case .working: .working
            case .needsYou: .needsYou
            case .withPR: .withPR
            }
        }
    }
    private var filter = Filter(rawValue: UserDefaults.standard.string(forKey: "sidebar.filter") ?? "") ?? .all
    static var pinned: [String] {
        get { UIState.strings("sidebar.pinned") }
        set { UIState["sidebar.pinned"] = try? .from(newValue) }
    }
    private let noMatch = NSStackView()
    private let summary = AgentSummary()

    override func loadView() {
        let col = NSTableColumn(identifier: .init("main")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil; outline.style = .sourceList; outline.rowSizeStyle = .custom
        outline.floatsGroupRows = false; outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = true   // ⌘/⇧-click: the menu then acts on all of them
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL, Self.rowType])   // a folder from Finder becomes a project; rows move
        outline.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                               owner: self, userInfo: nil))
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
        search.placeholderString = String(localized: "Workspace or agent"); search.delegate = self; search.controlSize = .small
        search.sendsSearchStringImmediately = true; search.target = self; search.action = #selector(searchChanged)
        setFilterMenu()
        // Beside the search, over the projects it adds to, where people look for it.
        let add = NSButton.titlebar("folder.badge.plus", String(localized: "Add Project"), tip: String(localized: "Add a project: a folder, a clone or one over SSH"))
        add.target = self; add.action = #selector(addMenu(_:))
        for x in [add, search, summary, scroll, footer, empty, noMatch] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            // Under the traffic lights, in the window's second row: level with the tab strips and the inspector's panel icons.
            search.centerYAnchor.constraint(equalTo: v.topAnchor, constant: WindowBar.height + TabStrip.height / 2),
            search.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10), search.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -4),
            add.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6), add.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            summary.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8), summary.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: v.leadingAnchor), footer.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.centerYAnchor.constraint(equalTo: v.centerYAnchor, constant: -40),
            empty.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -32),
            noMatch.centerXAnchor.constraint(equalTo: v.centerXAnchor), noMatch.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 40),
            noMatch.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -32)
        ])
        buildEmpty()
        view = v
        track(owner: self) { AppModel.shared.repos } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { AppModel.shared.worktrees } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { AppModel.shared.sessions } changed: { [weak self] in self?.refresh(); self?.summary.update($0) }
        track(owner: self) { AppModel.shared.order } changed: { [weak self] _ in self?.refresh() }
        track(owner: self) { Workbench.shared.workspaceId } changed: { [weak self] _ in self?.syncSelection() }
        track(owner: self) { RowBadges.shared.stats } changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { RowBadges.shared.prs } changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { SettingsStore.shared.string("workbench.textSize") } changed: { [weak self] _ in self?.refresh() }
        // "now" becomes "1m": the times on the right move on their own.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateVisibleCells() } }
    }

    private func updateVisibleCells() {
        for row in 0..<outline.numberOfRows { (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.update() }
    }

    /// Nothing matches the search or the filter: say which, and offer the way back.
    private func showNoMatch(_ on: Bool) {
        noMatch.isHidden = !on
        guard on else { return }
        noMatch.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let what = query.isEmpty ? "“\(loc(filter.rawValue))”" : "“\(query)”" + (filter == .all ? "" : String(localized: " in “\(loc(filter.rawValue))”"))
        let t = NSTextField(wrappingLabelWithString: String(localized: "No workspaces match \(what).")); t.alignment = .center; t.textColor = .secondaryLabelColor
        let b = ClosureButton(title: String(localized: "Show All")) { [weak self] in
            guard let self else { return }
            search.stringValue = ""; query = ""; setFilter(.all)
        }
        b.bezelStyle = .push; b.controlSize = .small
        [t, b].forEach { noMatch.addArrangedSubview($0) }
        noMatch.orientation = .vertical; noMatch.spacing = 8
    }

    private func setFilterMenu() {
        let m = NSMenu()
        for f in Filter.allCases {
            let i = m.add(loc(f.rawValue)) { [weak self] in self?.setFilter(f) }
            i.state = f == filter ? .on : .off
        }
        search.searchMenuTemplate = m
        search.placeholderString = filter == .all ? String(localized: "Workspace or agent") : String(localized: "Search \(loc(filter.rawValue))")
    }
    private func setFilter(_ f: Filter) {
        filter = f; UserDefaults.standard.set(f.rawValue, forKey: "sidebar.filter")
        setFilterMenu(); refresh()
    }

    // MARK: hover cards

    override func mouseMoved(with e: NSEvent) {
        let row = outline.row(at: outline.convert(e.locationInWindow, from: nil))
        guard row >= 0, renaming == nil, let n = outline.item(atRow: row) as? Node, !n.key.hasPrefix("s:") else { card.hover(nil, rect: .zero, in: outline); return }
        card.hover(n.key.replacingOccurrences(of: "n:", with: "a:"), rect: outline.rect(ofRow: row), in: outline)
    }
    override func mouseExited(with e: NSEvent) { card.hover(nil, rect: .zero, in: outline) }

    private func buildEmpty() {
        let icon = NSImageView(image: .symbol("folder.badge.plus")); icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let t = NSTextField(labelWithString: String(localized: "No Projects")); t.font = .ui(13, weight: .semibold)
        let d = NSTextField(wrappingLabelWithString: String(localized: "Add a git repository to start.")); d.textColor = .secondaryLabelColor; d.alignment = .center
        let b = ClosureButton(title: String(localized: "Add Project…")) { Workbench.addProject() }; b.bezelStyle = .push
        [icon, t, d, b].forEach { empty.addArrangedSubview($0) }
        empty.orientation = .vertical; empty.spacing = 8
    }

    // MARK: model → tree

    private var needsOrder = StableOrder()

    private func build() -> [Node] {
        let m = AppModel.shared
        var tree = SidebarTree(projects: m.projects, workspaces: m.projects.flatMap { m.workspaces(of: $0) }, sessions: m.sessions, attention: AttentionQueue.sessions)
        tree.pinned = Self.pinned
        tree.query = query
        tree.filter = filter.tree
        tree.current = Workbench.shared.workspaceId
        tree.statusLabel = { $0.label }
        tree.hasPR = { w in (RowBadges.folder(workspace: w.id) ?? RowBadges.folder(project: w.repoId)).map { RowBadges.shared.prs[$0.id] != nil } ?? false }
        tree.stableOrder = { [unowned self] in needsOrder($0) }
        func node(_ i: SidebarItem) -> Node {
            let n: Node
            switch i.kind {
            case .project(let id): n = Node(.project(id))
            case .workspace(let id): n = Node(.workspace(id))
            case .agent(let id): n = Node(.agent(id))
            case .section(let s): n = Node(.section(s))
            case .needs(let id): n = Node(.needs(id))
            }
            n.children = i.children.map(node)
            return n
        }
        return tree.build().map(node)
    }

    /// The ways in, as File shows them: a folder (new or existing), a clone, a project over SSH.
    @objc private func addMenu(_ b: NSButton) {
        guard let d = NSApp.delegate as? AppDelegate else { return }
        let m = NSMenu()
        for id in ["workspace.addProject", "workspace.cloneRepository", "workspace.addRemote"] { if let c = ExtensionRegistry.shared.command(id) { m.addItem(d.item(c)) } }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc private func searchChanged() { query = search.stringValue.trimmingCharacters(in: .whitespaces); refresh() }

    /// Same shape → refresh the visible cells; new shape → reload, keeping expansion and selection.
    private func refresh() {
        let next = build()
        func flat(_ ns: [Node]) -> [String] { ns.flatMap { [$0.key] + flat($0.children) } }
        let nextShape = flat(next)
        let projects = AppModel.shared.repos.filter { !ScratchWindow.isScratch($0) }
        empty.isHidden = !projects.isEmpty
        showNoMatch(!projects.isEmpty && !next.contains { if case .project = $0.kind { true } else { false } })
        search.isHidden = projects.isEmpty
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
    static func isHeader(_ item: Any?) -> Bool {
        switch (item as? Node)?.kind {
        case .project?, .section?: true
        default: false
        }
    }
    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { Self.isHeader(item) }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { !Self.isHeader(item) }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { !Self.isHeader(item) }
    // One line per row, like Mail's mailbox list; section headers a little taller for air above them, and an agent
    // with news two lines (what it asks or did under its name).
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return TextSize.of(Self.isHeader(item) ? 32 : 28)
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
        refreshCell(node.key)   // collapsed, the workspace shows its agents' state itself
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        card.close()
        // Several rows picked: nothing to open, they wait for the menu.
        guard !syncing, outline.selectedRowIndexes.count == 1, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        switch node.kind {
        case .workspace(let id): Workbench.show(workspace: id)
        case .agent(let id), .needs(let id): Workbench.focus(session: id)
        case .project, .section: break
        }
    }

    // MARK: dragging: rows among their own, folders from Finder

    static let rowType = NSPasteboard.PasteboardType("dev.kelp.sidebar-row")

    /// Projects and pinned or project workspaces move; not while the list is narrowed (the hidden ones would jump).
    func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard query.isEmpty, filter == .all, let n = item as? Node, n.id != nil else { return nil }
        let p = NSPasteboardItem(); p.setString(n.key, forType: Self.rowType)
        return p
    }
    func outlineView(_ o: NSOutlineView, draggingSession s: NSDraggingSession, willBeginAt p: NSPoint, forItems items: [Any]) { card.close() }

    /// The dragged row and where it lands among its siblings: before the block (the row and what's under it) the
    /// pointer is over, or after it past its middle. Projects stay under the sections; a workspace stays in its project.
    private func move(_ info: NSDraggingInfo) -> (node: Node, parent: Node?, index: Int)? {
        let pb = info.draggingPasteboard
        guard info.draggingSource as? NSOutlineView === outline, pb.pasteboardItems?.count == 1,
              let key = pb.string(forType: Self.rowType), let n = node(key) else { return nil }
        let parent = outline.parent(forItem: n) as? Node
        let siblings = parent?.children ?? roots
        let firstProject = parent == nil ? roots.firstIndex { if case .project = $0.kind { true } else { false } } ?? 0 : 0
        let p = outline.convert(info.draggingLocation, from: nil)
        var over = outline.item(atRow: outline.row(at: p)) as? Node
        while let o = over, outline.parent(forItem: o) as? Node !== parent { over = outline.parent(forItem: o) as? Node }
        guard let o = over, let i = siblings.firstIndex(of: o) else { return parent == nil ? (n, nil, siblings.count) : nil }
        var last = o
        while outline.isItemExpanded(last), let c = last.children.last { last = c }
        let block = outline.rect(ofRow: outline.row(forItem: o)).union(outline.rect(ofRow: outline.row(forItem: last)))
        return (n, parent, max(firstProject, p.y < block.midY ? i : i + 1))
    }

    private static func folders(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.path)
    }
    func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if info.draggingPasteboard.types?.contains(Self.rowType) == true {
            guard let m = move(info) else { return [] }
            o.setDropItem(m.parent, dropChildIndex: m.index)
            return .move
        }
        guard !Self.folders(info).isEmpty else { return [] }
        o.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)   // the whole list, not a row
        return .copy
    }
    func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let m = move(info) {
            var rows = m.parent?.children ?? roots
            guard let from = rows.firstIndex(of: m.node) else { return false }
            rows.insert(m.node, at: m.index); rows.remove(at: from < m.index ? from : from + 1)
            let ids = rows.compactMap(\.id)
            if case .section = m.parent?.kind { Self.pinned = ids + Self.pinned.filter { !ids.contains($0) }; refresh() } else { AppModel.shared.reorder(ids) }
            return true
        }
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
            Task { await AppModel.shared.call(WorktreeNote(id: id, note: name)) }
        } else { refreshCell("w:" + id) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        card.close()
        guard let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
        let m = AppModel.shared
        let picked = outline.selectedRowIndexes
        if picked.count > 1, picked.contains(outline.clickedRow) {
            bulkMenu(menu, picked.compactMap { outline.item(atRow: $0) as? Node }); return
        }
        switch n.kind {
        case .project(let id):
            guard let r = m.repo(id) else { return }
            if !FileManager.default.fileExists(atPath: r.path) {
                menu.add(String(localized: "Locate…")) { WorkspaceActions.relocate(r) }
                menu.add(String(localized: "Remove from Kelp…")) { WorkspaceActions.removeProject(r) }
                return
            }
            menu.add(String(localized: "New Workspace")) { [weak self] in self?.newWorkspace(id) }
            menu.add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
            menu.addItem(.separator())
            if RemoteHost.of(r.path) == nil { menu.add(String(localized: "Remove Clean Worktrees…")) { WorkspaceActions.removeCleanWorktrees(r) } }
            menu.add(String(localized: "Remove Project…")) { WorkspaceActions.removeProject(r) }
        case .section: return
        case .needs(let sid):
            menu.add(String(localized: "Show")) { Workbench.focus(session: sid) }
            if m.session(sid)?.unread == true { menu.add(String(localized: "Mark as Read")) { Task { await AppModel.shared.call("session.markRead", .obj(["id": .string(sid)])) } } }
        case .workspace(let id):
            guard let w = m.worktree(id) else { return }
            let pinned = Self.pinned.contains(id)
            menu.add(pinned ? String(localized: "Unpin") : String(localized: "Pin to Top")) { [weak self] in
                Self.pinned = pinned ? Self.pinned.filter { $0 != id } : Self.pinned + [id]; self?.refresh()
            }
            menu.add(String(localized: "Rename")) { [weak self] in self?.startRename(id) }
            menu.add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
            menu.add(String(localized: "Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(w.path, forType: .string) }
            WorkspaceActions.addOpenIn(to: menu, path: w.path)
            menu.addItem(.separator())
            if w.path == m.repo(w.repoId)?.path {
                // A desk: archiving pauses its agents and keeps its tabs (Window › Archived Workspaces brings it back);
                // with ⌥ the item closes it instead, ending its agents. The project's folder is untouched either way.
                let more = m.worktrees.filter { $0.repoId == w.repoId && $0.path == w.path && !$0.archived }.count > 1
                let archive = menu.add(String(localized: "Archive")) { WorkspaceActions.archive(w) }
                archive.isEnabled = more
                let close = menu.add(String(localized: "Close Workspace")) { WorkspaceActions.close(w) }
                close.isAlternate = true; close.keyEquivalentModifierMask = .option; close.isEnabled = more
            } else {
                menu.add(String(localized: "Archive")) { Task { await AppModel.shared.call("worktree.archive", .obj(["id": .string(id)])) } }
                menu.add(String(localized: "Delete Workspace & Branch…")) { WorkspaceActions.delete(w) }
            }
        case .agent(let sid):
            menu.add(String(localized: "Show")) { Workbench.focus(session: sid) }
            menu.add(String(localized: "Rename…")) { AgentActions.rename(sid) }
            menu.add(String(localized: "Restart")) { AgentActions.restart(sid) }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy Context")) { AgentActions.copyContext(sid) }
            menu.setSubmenu(AgentActions.handoffMenu(sid), for: menu.addItem(withTitle: String(localized: "Hand Off to"), action: nil, keyEquivalent: ""))
            if m.session(sid)?.unread == false { menu.add(String(localized: "Mark as Unread")) { Task { await AppModel.shared.call("session.markUnread", .obj(["id": .string(sid)])) } } }
            menu.addItem(.separator())
            menu.add(String(localized: "Stop")) { Task { await AppModel.shared.call("session.kill", .obj(["id": .string(sid)])) } }
        }
    }
}

extension SidebarController {
    /// The menu for several selected rows: what applies to all of them.
    private func bulkMenu(_ menu: NSMenu, _ nodes: [Node]) {
        let m = AppModel.shared
        let ws = nodes.compactMap { n -> Worktree? in if case .workspace(let id) = n.kind { m.worktree(id) } else { nil } }
        let picked = nodes.compactMap { n -> String? in
            switch n.kind {
            case .agent(let id), .needs(let id): id
            default: nil
            }
        }
        let inside = m.sessions.filter { s in ws.contains { $0.id == s.worktreeId } && s.agent != "shell" && s.status != .exited }.map(\.id)
        let agents = Array(Set(picked + inside))
        if agents.contains(where: { m.session($0)?.unread == true }) {
            menu.add(String(localized: "Mark as Read")) {
                for id in agents where m.session(id)?.unread == true { Task { await m.call("session.markRead", .obj(["id": .string(id)])) } }
            }
        }
        if !ws.isEmpty { menu.add(String(localized: "Close \(ws.count) Workspaces…")) { WorkspaceActions.close(ws) } }
        if !picked.isEmpty {
            menu.addItem(.separator())
            menu.add(String(localized: "Stop \(Set(picked).count) Agents…")) { AgentActions.stop(Array(Set(picked))) }
        }
    }
}
