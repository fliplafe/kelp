import AppKit
import SwiftUI
import Core
import GitKit

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
        /// The agent a row stands for.
        var session: String? {
            switch kind {
            case .agent(let id), .needs(let id): id
            default: nil
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
    enum Filter: String, CaseIterable { case all = "All Workspaces", working = "Working", needsYou = "Needs You", withPR = "With a Pull Request" }
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
        let add = NSButton.titlebar("folder.badge.plus", String(localized: "Add Project"), tip: String(localized: "Add a project folder (⌘O)"))
        add.identifier = .init("workspace.addProject"); add.target = NSApp.delegate; add.action = #selector(AppDelegate.runCommand(_:))
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

    /// Rows don't jump under the pointer: what needs you keeps its place, new ones join at the end, and the list is put
    /// back in the queue's order (questions first, oldest first) only every few minutes.
    private var needsOrder: [String] = [], needsSortedAt = Date.distantPast
    private func stableOrder(_ fresh: [String]) -> [String] {
        if Date().timeIntervalSince(needsSortedAt) > 180 { needsOrder = fresh; needsSortedAt = Date(); return fresh }
        needsOrder = needsOrder.filter(fresh.contains) + fresh.filter { !needsOrder.contains($0) }
        return needsOrder
    }

    private func build() -> [Node] {
        let m = AppModel.shared
        let q = query.lowercased()
        let narrowed = !q.isEmpty || filter != .all
        let pins = Self.pinned
        func hit(_ text: String...) -> Bool { q.isEmpty || text.contains { $0.lowercased().contains(q) } }
        func passes(_ w: Worktree, _ agents: [Session]) -> Bool {
            if w.id == Workbench.shared.workspaceId { return true }   // the one on screen never vanishes from the list
            switch filter {
            case .all: return true
            case .working: return agents.contains { $0.status == .working }
            case .needsYou: return agents.contains { [.waiting, .error].contains($0.status) || ($0.status == .done && $0.unread) }
            case .withPR:
                let folder = RowBadges.folder(workspace: w.id) ?? RowBadges.folder(project: w.repoId)
                return folder.map { RowBadges.shared.prs[$0.id] != nil } ?? false
            }
        }
        func workspace(_ w: Worktree, _ r: Repo) -> Node? {
            // Agents only: terminals are tabs, not something to keep an eye on.
            let agents = m.sessions.filter { $0.worktreeId == w.id && $0.status != .exited && $0.agent != "shell" }
            guard passes(w, agents) else { return nil }
            let whole = hit(w.displayName, w.branch, r.name)
            let kept = whole ? agents : agents.filter { hit($0.title, $0.agent ?? "", $0.summary, $0.status.label) }   // "needs", "working", "done" act as filters
            guard whole || !kept.isEmpty else { return nil }
            let n = Node(.workspace(w.id))
            n.children = kept.map { Node(.agent($0.id)) }
            return n
        }
        var out: [Node] = []
        // Over the projects: what needs you, from all of them (with more than a couple of workspaces), then the
        // workspaces you pinned (moved up, not copied).
        let needs = AttentionQueue.sessions.filter { s in m.worktree(s.worktreeId) != nil && hit(s.title, s.agent ?? "", s.summary) }
        if !needs.isEmpty, filter == .all || filter == .needsYou, m.worktrees.filter({ !$0.archived }).count > 2 {
            let n = Node(.section("Needs You")); n.children = stableOrder(needs.map(\.id)).map { Node(.needs($0)) }; out.append(n)
        }
        let pinnedNodes = pins.compactMap { id in m.worktree(id).flatMap { w in m.repo(w.repoId).flatMap { workspace(w, $0) } } }
        if !pinnedNodes.isEmpty { let n = Node(.section("Pinned")); n.children = pinnedNodes; out.append(n) }
        out += m.projects.compactMap { r in
            let p = Node(.project(r.id))
            p.children = m.workspaces(of: r).filter { !pins.contains($0.id) }.compactMap { workspace($0, r) }
            return p.children.isEmpty && narrowed ? nil : p
        }
        return out
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
