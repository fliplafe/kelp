import AppKit
import Core

final class SidebarItem: NSObject {
    enum Kind { case repo(Repo), worktree(Worktree), session(Session) }
    let kind: Kind
    init(_ k: Kind) { kind = k }
    var id: String {
        switch kind { case .repo(let r): "r" + r.id; case .worktree(let w): "w" + w.id; case .session(let s): "s" + s.id }
    }
}

/// Projects → worktrees → sessions, with status badges.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let outline = NSOutlineView()
    private var items: [SidebarItem] = []
    private var kids: [String: [SidebarItem]] = [:]
    var onSelectWorktree: ((Worktree?) -> Void)?
    var onSelectSession: ((Session) -> Void)?
    private var reloading = false

    override func loadView() {
        let col = NSTableColumn(identifier: .init("main")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil; outline.style = .sourceList; outline.rowSizeStyle = .medium
        outline.dataSource = self; outline.delegate = self
        outline.autosaveExpandedItems = false
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu
        outline.doubleAction = #selector(doubleClicked); outline.target = self
        let sv = NSScrollView(); sv.documentView = outline; sv.hasVerticalScroller = true; sv.drawsBackground = false
        view = sv
        AppModel.shared.onChange.append { [weak self] in self?.reload() }
    }

    func reload() {
        let m = AppModel.shared
        let selected = (outline.item(atRow: outline.selectedRow) as? SidebarItem)?.id
        let expanded = Set((0..<outline.numberOfRows).compactMap { r in (outline.item(atRow: r) as? SidebarItem).flatMap { outline.isItemExpanded($0) ? $0.id : nil } })
        items = m.repos.map { SidebarItem(.repo($0)) }
        kids = [:]
        for r in m.repos {
            kids["r" + r.id] = m.worktrees.filter { $0.repoId == r.id }.map { SidebarItem(.worktree($0)) }
        }
        for w in m.worktrees {
            kids["w" + w.id] = m.sessions.filter { $0.worktreeId == w.id && $0.status != .exited }.map { SidebarItem(.session($0)) }
        }
        reloading = true
        outline.reloadData()
        for it in allItems() where expanded.contains(it.id) || (expanded.isEmpty && !isSession(it)) { outline.expandItem(it) }
        if let selected, let it = allItems().first(where: { $0.id == selected }) {
            let row = outline.row(forItem: it); if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
        reloading = false
    }
    private func isSession(_ i: SidebarItem) -> Bool { if case .session = i.kind { true } else { false } }
    private func allItems() -> [SidebarItem] { items + items.flatMap { kids[$0.id] ?? [] } + items.flatMap { kids[$0.id] ?? [] }.flatMap { kids[$0.id] ?? [] } }

    func select(worktree id: String) {
        guard let it = allItems().first(where: { $0.id == "w" + id }) else { return }
        let row = outline.row(forItem: it); if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
    }
    var selectedWorktree: Worktree? {
        var it = outline.item(atRow: outline.selectedRow) as? SidebarItem
        if case .session(let s)? = it?.kind { it = allItems().first { $0.id == "w" + (s.worktreeId ?? "") } }
        if case .worktree(let w)? = it?.kind { return w }
        return nil
    }
    var selectedRepo: Repo? {
        guard let it = outline.item(atRow: outline.selectedRow) as? SidebarItem else { return AppModel.shared.repos.first }
        switch it.kind {
        case .repo(let r): return r
        case .worktree(let w): return AppModel.shared.repo(w.repoId)
        case .session(let s): return AppModel.shared.repo(AppModel.shared.worktree(s.worktreeId)?.repoId)
        }
    }

    // MARK: data source
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? SidebarItem).map { kids[$0.id]?.count } ?? items.count) ?? 0 }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? SidebarItem).map { kids[$0.id]![index] } ?? items[index] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? SidebarItem).map(isSession) ?? false) }

    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let it = item as? SidebarItem else { return nil }
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: ""); tf.lineBreakMode = .byTruncatingTail
        let img = NSImageView()
        cell.addSubview(tf); cell.addSubview(img); cell.textField = tf; cell.imageView = img
        for v in [tf, img] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 14),
            tf.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 4), tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        ])
        let tfCenter: NSLayoutConstraint? = tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor); tfCenter?.isActive = true
        switch it.kind {
        case .repo(let r):
            tf.stringValue = r.name; tf.font = .systemFont(ofSize: 12, weight: .semibold)
            img.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        case .worktree(let w):
            tf.stringValue = w.branch
            cell.toolTip = w.note.isEmpty ? w.path : "\(w.note)\n\(w.path)"
            if !w.note.isEmpty {   // second line: the progress note
                let note = NSTextField(labelWithString: w.note); note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
                note.lineBreakMode = .byTruncatingTail; note.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(note)
                NSLayoutConstraint.activate([note.leadingAnchor.constraint(equalTo: tf.leadingAnchor), note.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                                             note.topAnchor.constraint(equalTo: tf.bottomAnchor, constant: 1)])
                tfCenter?.constant = -7
            }
            img.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
            let ss = AppModel.shared.sessions.filter { $0.worktreeId == w.id && $0.status != .exited }
            if ss.contains(where: \.unread) { tf.font = .boldSystemFont(ofSize: 12) }
            img.contentTintColor = ss.contains { $0.status == .waiting } ? .systemOrange : ss.contains { $0.status == .working } ? .systemBlue : .secondaryLabelColor
        case .session(let s):
            tf.stringValue = s.displayTitle; tf.font = .systemFont(ofSize: 12, weight: s.unread ? .semibold : .regular)
            cell.toolTip = "\(s.agent ?? "shell") · \(s.status.label)" + (s.summary.isEmpty ? "" : "\n\(s.summary)")
            img.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: s.status.rawValue)
            img.symbolConfiguration = .init(pointSize: 7, weight: .regular)
            img.contentTintColor = [AgentStatus.working: .systemBlue, .waiting: .systemOrange, .done: .systemGreen, .idle: .systemGray, .exited: .systemRed][s.status]
        }
        return cell
    }

    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if case .worktree(let w)? = (item as? SidebarItem)?.kind, !w.note.isEmpty { return 38 }
        return 24
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !reloading else { return }
        onSelectWorktree?(selectedWorktree)
        if case .session(let s)? = (outline.item(atRow: outline.selectedRow) as? SidebarItem)?.kind { onSelectSession?(s) }
    }
    @objc private func doubleClicked() {
        if case .session(let s)? = (outline.item(atRow: outline.clickedRow) as? SidebarItem)?.kind { onSelectSession?(s) }
    }

    // MARK: context menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let it = outline.item(atRow: outline.clickedRow) as? SidebarItem else { return }
        guard let d = NSApp.delegate as? AppDelegate else { return }
        switch it.kind {
        case .repo(let r):
            menu.addItem(withTitle: "New Worktree…", action: #selector(AppDelegate.newWorktree), keyEquivalent: "").target = d
            let rm = menu.addItem(withTitle: "Remove Project", action: #selector(removeRepo(_:)), keyEquivalent: ""); rm.target = self; rm.representedObject = r.id
        case .worktree(let w):
            for (t, a) in [("Edit Note…", #selector(editNote(_:))), ("Archive", #selector(archive(_:))), ("Delete Worktree & Branch…", #selector(remove(_:)))] {
                let m = menu.addItem(withTitle: t, action: a, keyEquivalent: ""); m.target = self; m.representedObject = w.id
            }
        case .session(let s):
            let m = menu.addItem(withTitle: "Kill Session", action: #selector(kill(_:)), keyEquivalent: ""); m.target = self; m.representedObject = s.id
        }
    }
    @objc private func removeRepo(_ m: NSMenuItem) { Task { await AppModel.shared.call("repo.remove", .obj(["id": .string(m.representedObject as? String ?? "")])) } }
    @objc private func kill(_ m: NSMenuItem) { Task { await AppModel.shared.call("session.kill", .obj(["id": .string(m.representedObject as? String ?? "")])) } }
    @objc private func archive(_ m: NSMenuItem) { Task { await AppModel.shared.call("worktree.archive", .obj(["id": .string(m.representedObject as? String ?? "")])) } }
    @objc private func editNote(_ m: NSMenuItem) {
        let id = m.representedObject as? String ?? ""
        guard let text = prompt("Worktree note", "Short progress note", initial: AppModel.shared.worktree(id)?.note ?? "") else { return }
        Task { await AppModel.shared.call("worktree.note", .obj(["id": .string(id), "note": .string(text)])) }
    }
    @objc private func remove(_ m: NSMenuItem) {
        let id = m.representedObject as? String ?? ""
        Task {
            let dirty = await AppModel.shared.call("worktree.dirty", .obj(["id": .string(id)]))?.bool ?? false
            let a = NSAlert(); a.messageText = "Delete worktree and its branch?"
            a.informativeText = dirty ? "⚠️ It has uncommitted changes that will be lost." : "The checkout and the branch are removed."
            a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel"); a.alertStyle = dirty ? .critical : .warning
            guard a.runModal() == .alertFirstButtonReturn else { return }
            await AppModel.shared.call("worktree.remove", .obj(["id": .string(id), "force": .bool(dirty)]))
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
