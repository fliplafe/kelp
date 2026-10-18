import AppKit
import Core

final class SidebarItem: NSObject {
    enum Kind { case repo(Repo), worktree(Worktree) }
    let kind: Kind
    init(_ k: Kind) { kind = k }
    var id: String {
        switch kind {
        case .repo(let r): "r" + r.id
        case .worktree(let w): "w" + w.id
        }
    }
}

/// Projects → workspaces. Each workspace row shows what its agents are doing; "+" on a project starts a new one.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let outline = NSOutlineView()
    private var items: [SidebarItem] = []
    private var kids: [String: [SidebarItem]] = [:]
    var onSelectWorktree: ((Worktree?) -> Void)?
    private var reloading = false

    override func loadView() {
        let col = NSTableColumn(identifier: .init("main")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil; outline.style = .sourceList; outline.rowSizeStyle = .custom
        outline.dataSource = self; outline.delegate = self
        outline.autosaveExpandedItems = false; outline.floatsGroupRows = false
        outline.indentationPerLevel = 0
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu
        let sv = NSScrollView(); sv.documentView = outline; sv.hasVerticalScroller = true; sv.drawsBackground = false
        sv.automaticallyAdjustsContentInsets = true

        let add = NSButton(title: "Add Repository", image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!,
                           target: NSApp.delegate, action: #selector(AppDelegate.addProject))
        add.isBordered = false; add.imagePosition = .imageLeading; add.contentTintColor = .secondaryLabelColor; add.font = .systemFont(ofSize: 12)
        add.toolTip = "Add a git repository (⌘O)"
        let sep = NSBox(); sep.boxType = .separator
        let v = NSView()
        for x in [sv, sep, add] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: v.topAnchor), sv.leadingAnchor.constraint(equalTo: v.leadingAnchor), sv.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: sep.topAnchor),
            sep.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10), sep.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            sep.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -6),
            add.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14), add.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            add.heightAnchor.constraint(equalToConstant: 22),
        ])
        view = v
        AppModel.shared.onChange.append { [weak self] in self?.reload() }
    }

    func reload() {
        let m = AppModel.shared
        let selected = (outline.item(atRow: outline.selectedRow) as? SidebarItem)?.id
        items = m.repos.map { SidebarItem(.repo($0)) }
        kids = [:]
        for r in m.repos {
            // Newest first, like a task list.
            kids["r" + r.id] = m.worktrees.filter { $0.repoId == r.id && !$0.archived }.sorted { $0.createdAt > $1.createdAt }.map { SidebarItem(.worktree($0)) }
        }
        reloading = true
        outline.reloadData()
        items.forEach { outline.expandItem($0) }
        if let selected, let it = allItems().first(where: { $0.id == selected }) {
            let row = outline.row(forItem: it); if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
        reloading = false
    }
    private func allItems() -> [SidebarItem] { items + items.flatMap { kids[$0.id] ?? [] } }

    func select(worktree id: String) {
        guard let it = allItems().first(where: { $0.id == "w" + id }) else { return }
        let row = outline.row(forItem: it); if row >= 0 { reloading = true; outline.selectRowIndexes([row], byExtendingSelection: false); reloading = false }
    }
    var selectedWorktree: Worktree? {
        if case .worktree(let w)? = (outline.item(atRow: outline.selectedRow) as? SidebarItem)?.kind { return w }
        return nil
    }
    var selectedRepo: Repo? {
        guard let it = outline.item(atRow: outline.selectedRow) as? SidebarItem else { return AppModel.shared.repos.first }
        switch it.kind {
        case .repo(let r): return r
        case .worktree(let w): return AppModel.shared.repo(w.repoId)
        }
    }

    // MARK: data source
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? SidebarItem).map { kids[$0.id]?.count } ?? items.count) ?? 0 }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? SidebarItem).map { kids[$0.id]![index] } ?? items[index] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { if case .repo? = (item as? SidebarItem)?.kind { true } else { false } }
    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { if case .repo? = (item as? SidebarItem)?.kind { true } else { false } }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { if case .worktree? = (item as? SidebarItem)?.kind { true } else { false } }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let it = item as? SidebarItem else { return nil }
        switch it.kind {
        case .repo(let r): return RepoHeader(repo: r)
        case .worktree(let w): return WorkspaceRow(worktree: w)
        }
    }

    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if case .repo? = (item as? SidebarItem)?.kind { return 30 }
        return 44
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !reloading else { return }
        onSelectWorktree?(selectedWorktree)
    }

    // MARK: context menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let it = outline.item(atRow: outline.clickedRow) as? SidebarItem else { return }
        guard let d = NSApp.delegate as? AppDelegate else { return }
        switch it.kind {
        case .repo(let r):
            let n = menu.addItem(withTitle: "New Workspace…", action: #selector(newWorkspace(_:)), keyEquivalent: ""); n.target = self; n.representedObject = r
            _ = d
            menu.addItem(.separator())
            let rm = menu.addItem(withTitle: "Remove Repository", action: #selector(removeRepo(_:)), keyEquivalent: ""); rm.target = self; rm.representedObject = r.id
        case .worktree(let w):
            for (t, a) in [("Edit Note…", #selector(editNote(_:))), ("Reveal in Finder", #selector(reveal(_:))), ("Archive", #selector(archive(_:)))] {
                let m = menu.addItem(withTitle: t, action: a, keyEquivalent: ""); m.target = self; m.representedObject = w.id
            }
            menu.addItem(.separator())
            let m = menu.addItem(withTitle: "Delete Workspace & Branch…", action: #selector(remove(_:)), keyEquivalent: ""); m.target = self; m.representedObject = w.id
        }
    }
    @objc private func removeRepo(_ m: NSMenuItem) { Task { await AppModel.shared.call("repo.remove", .obj(["id": .string(m.representedObject as? String ?? "")])) } }
    @objc private func newWorkspace(_ m: NSMenuItem) { WorkspaceComposer.show(repo: m.representedObject as? Repo) }
    @objc private func reveal(_ m: NSMenuItem) {
        if let w = AppModel.shared.worktree(m.representedObject as? String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
    }
    @objc private func archive(_ m: NSMenuItem) { Task { await AppModel.shared.call("worktree.archive", .obj(["id": .string(m.representedObject as? String ?? "")])) } }
    @objc private func editNote(_ m: NSMenuItem) {
        let id = m.representedObject as? String ?? ""
        guard let text = prompt("Workspace note", "A short note about this workspace, shown under its name.", initial: AppModel.shared.worktree(id)?.note ?? "") else { return }
        Task { await AppModel.shared.call("worktree.note", .obj(["id": .string(id), "note": .string(text)])) }
    }
    @objc private func remove(_ m: NSMenuItem) {
        let id = m.representedObject as? String ?? ""
        Task {
            let dirty = await AppModel.shared.call("worktree.dirty", .obj(["id": .string(id)]))?.bool ?? false
            let a = NSAlert(); a.messageText = "Delete this workspace and its branch?"
            a.informativeText = dirty ? "⚠️ It has uncommitted changes that will be lost." : "The checkout and the branch are removed."
            a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel"); a.alertStyle = dirty ? .critical : .warning
            guard a.runModal() == .alertFirstButtonReturn else { return }
            await AppModel.shared.call("worktree.remove", .obj(["id": .string(id), "force": .bool(dirty)]))
            Attribution.reset(worktree: id)
        }
    }
}

@MainActor
func prompt(_ title: String, _ info: String, initial: String = "") -> String? {
    let a = NSAlert(); a.messageText = title; a.informativeText = info
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); f.stringValue = initial
    a.accessoryView = f; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = f
    return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
}

/// Project heading with a "+" for a new workspace in it.
@MainActor
private final class RepoHeader: NSTableCellView {
    init(repo: Repo) {
        super.init(frame: .zero)
        let t = NSTextField(labelWithString: repo.name); t.font = .systemFont(ofSize: 11, weight: .semibold); t.textColor = .secondaryLabelColor
        t.toolTip = repo.path
        let add = ClosureButton(title: "") { WorkspaceComposer.show(repo: repo) }
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New workspace in \(repo.name)")
        add.isBordered = false; add.contentTintColor = .secondaryLabelColor; add.toolTip = "New workspace in \(repo.name) (⌘N)"
        add.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        for v in [t, add] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), t.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), add.centerYAnchor.constraint(equalTo: t.centerYAnchor),
            t.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Workspace row: name, then what its agents are doing (or the branch); bold while something new waits there.
@MainActor
private final class WorkspaceRow: NSTableCellView {
    init(worktree w: Worktree) {
        super.init(frame: .zero)
        let m = AppModel.shared
        let ss = m.sessions.filter { $0.worktreeId == w.id && $0.status != .exited && $0.agent != "shell" }
        let order: [AgentStatus] = [.waiting, .working, .done, .idle, .hibernated]
        let top = ss.min { (order.firstIndex(of: $0.status) ?? 9) < (order.firstIndex(of: $1.status) ?? 9) }
        let dot = StatusDot(status: top?.status)
        dot.isHidden = top == nil
        let branchIcon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)!)
        branchIcon.symbolConfiguration = .init(pointSize: 10, weight: .regular); branchIcon.contentTintColor = .tertiaryLabelColor
        branchIcon.isHidden = top != nil

        let title = NSTextField(labelWithString: w.branch)
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 13, weight: ss.contains(where: \.unread) ? .semibold : .regular)
        let detail: String
        let color: NSColor
        if let t = top {
            let summary = t.summary.isEmpty ? "" : " — " + t.summary
            detail = (t.status == .waiting ? "Needs your input" : t.status.label) + summary
            color = t.status == .waiting ? .systemOrange : .secondaryLabelColor
        } else { detail = w.note.isEmpty ? "No agent running" : w.note; color = .tertiaryLabelColor }
        let sub = NSTextField(labelWithString: detail); sub.font = .systemFont(ofSize: 11); sub.textColor = color; sub.lineBreakMode = .byTruncatingTail

        let links = [w.issue.isEmpty ? nil : w.issue, w.prNumber.map { "#\($0)" }].compactMap { $0 }
        let badge = NSTextField(labelWithString: links.joined(separator: " · "))
        badge.font = .systemFont(ofSize: 10, weight: .medium); badge.textColor = .secondaryLabelColor
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for v in [dot, branchIcon, title, sub, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            branchIcon.centerXAnchor.constraint(equalTo: dot.centerXAnchor), branchIcon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), badge.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor), sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
        textField = title
        toolTip = ([w.note, w.path] + [w.issueURL, w.prURL]).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    required init?(coder: NSCoder) { fatalError() }
}
