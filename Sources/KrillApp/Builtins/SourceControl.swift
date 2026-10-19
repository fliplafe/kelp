import AppKit
import UniformTypeIdentifiers
import Core
import GitKit

/// Source Control, modeled on VS Code's: branch and sync up top, the commit message, merge / staged / unstaged
/// changes (click → diff), and the history graph. All git work happens in the daemon; this only lays out the answers.
@MainActor
final class SourceControlController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    enum Section: String { case merge = "Merge Changes", staged = "Staged Changes", changes = "Changes", graph = "Graph" }

    final class Node: NSObject {
        enum Kind { case section(Section), file(FileChange, Section), commit(Int), commitFile(String, FileChange), note(String) }
        let kind: Kind
        var children: [Node] = []
        init(_ k: Kind) { kind = k }
    }

    private let outline = NSOutlineView()
    private let branchButton = NSButton()
    private let syncButton = NSButton()
    private let message = CommitTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let generate = NSButton()
    private var messageHeight: NSLayoutConstraint?
    private var commitButton: NSComboButton?
    private var moreButton: NSButton?
    private var commitArea: NSView?, separator: NSView?
    private let empty = NSTextField(wrappingLabelWithString: "")

    private var worktreeId: String?
    private var changes: [FileChange] = []
    private var info: BranchInfo?
    private var commits: [GraphCommit] = []
    private var more = false, limit = 200, loadingMore = false
    private var commitFiles: [String: [FileChange]] = [:]
    private var openCommits = Set<String>()
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "scm.collapsed") ?? [])
    private var roots: [Node] = []
    private var graphWidth: CGFloat = GraphView.width(lanes: 1)
    private var watcher: FileWatcher?
    private var pending: DispatchWorkItem?
    private var busy = false { didSet { updateCommitButton() } }

    // MARK: view

    override func loadView() {
        branchButton.isBordered = false; branchButton.imagePosition = .imageLeading; branchButton.imageHugsTitle = true
        branchButton.image = .symbol("arrow.triangle.branch"); branchButton.font = .systemFont(ofSize: 12, weight: .semibold)
        branchButton.lineBreakMode = .byTruncatingMiddle; branchButton.target = self; branchButton.action = #selector(branchMenu)
        branchButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchButton.toolTip = "Switch or create a branch"
        syncButton.isBordered = false; syncButton.imagePosition = .imageLeading; syncButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        syncButton.contentTintColor = .secondaryLabelColor; syncButton.target = self; syncButton.action = #selector(sync)
        let refresh = iconButton("arrow.clockwise", "Refresh") { [weak self] in self?.reloadAll() }
        let more = iconButton("ellipsis.circle", "More Actions") { [weak self] in self?.showMoreMenu() }
        moreButton = more
        let header = NSStackView(views: [branchButton, syncButton, NSView(), refresh, more])
        header.spacing = 6; header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)

        let box = commitBox(); commitArea = box
        let col = NSTableColumn(identifier: .init("scm")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil; outline.style = .plain; outline.backgroundColor = .clear
        outline.intercellSpacing = .zero; outline.indentationPerLevel = 0; outline.rowSizeStyle = .custom
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self; outline.delegate = self; outline.target = self; outline.action = #selector(clicked)
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        empty.alignment = .center; empty.textColor = .secondaryLabelColor; empty.isHidden = true
        let v = NSView()
        let sep = NSBox(); sep.boxType = .separator; separator = sep
        for x in [header, box, sep, scroll, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor), header.heightAnchor.constraint(equalToConstant: 32),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor), header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            box.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            box.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12), box.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            sep.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: v.leadingAnchor), sep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -40)
        ])
        view = v
        track { Workbench.shared.workspaceId } changed: { [weak self] in self?.bind($0) }
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: "", action: action)
        b.image = .symbol(symbol, tip); b.isBordered = false; b.toolTip = tip; b.contentTintColor = .secondaryLabelColor
        b.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        return b
    }

    /// The message field (grows to six lines), the on-device draft button inside it, and Commit with its split menu.
    private func commitBox() -> NSView {
        message.isRichText = false; message.font = .systemFont(ofSize: 13); message.drawsBackground = false
        message.textContainerInset = NSSize(width: 4, height: 6); message.allowsUndo = true
        message.isAutomaticQuoteSubstitutionEnabled = false; message.isAutomaticDashSubstitutionEnabled = false
        message.isVerticallyResizable = true; message.autoresizingMask = .width
        message.onCommit = { [weak self] in self?.commit(push: false, amend: false) }
        message.onChange = { [weak self] in self?.messageChanged() }
        let s = NSScrollView(); s.documentView = message; s.drawsBackground = false; s.hasVerticalScroller = false
        placeholder.textColor = .placeholderTextColor; placeholder.font = .systemFont(ofSize: 13); placeholder.lineBreakMode = .byTruncatingTail
        generate.image = .symbol("sparkles", "Draft with the on-device model"); generate.isBordered = false
        generate.contentTintColor = .secondaryLabelColor; generate.toolTip = "Draft a message from the changes (on-device)"
        generate.target = self; generate.action = #selector(draftMessage)
        let field = FieldBox(); field.wantsLayer = true
        let m = NSMenu()
        m.add("Commit & Push") { [weak self] in self?.commit(push: true, amend: false) }
        m.add("Commit (Amend)") { [weak self] in self?.commit(push: false, amend: true) }
        let cb = NSComboButton(title: "Commit", menu: m, target: self, action: #selector(commitPressed))
        cb.image = .symbol("checkmark", "Commit"); cb.style = .split; cb.controlSize = .large
        commitButton = cb
        let box = NSView()
        for x in [field, s, placeholder, generate, cb] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(x) }
        let h = s.heightAnchor.constraint(equalToConstant: 30); messageHeight = h
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: box.topAnchor), field.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            s.topAnchor.constraint(equalTo: field.topAnchor, constant: 1), s.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -1),
            s.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2), s.trailingAnchor.constraint(equalTo: generate.leadingAnchor), h,
            placeholder.leadingAnchor.constraint(equalTo: s.leadingAnchor, constant: 9), placeholder.topAnchor.constraint(equalTo: s.topAnchor, constant: 7),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: generate.leadingAnchor, constant: -2),
            generate.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -6), generate.topAnchor.constraint(equalTo: field.topAnchor, constant: 7),
            generate.widthAnchor.constraint(equalToConstant: 18),
            cb.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8), cb.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            cb.leadingAnchor.constraint(equalTo: box.leadingAnchor), cb.trailingAnchor.constraint(equalTo: box.trailingAnchor)
        ])
        return box
    }

    private func messageChanged() {
        placeholder.isHidden = !message.string.isEmpty
        if let lm = message.layoutManager, let tc = message.textContainer {
            lm.ensureLayout(for: tc)
            let lines = lm.usedRect(for: tc).height + message.textContainerInset.height * 2
            messageHeight?.constant = min(max(30, ceil(lines)), 6 * 17 + 12)
        }
        updateCommitButton()
    }

    private func updateCommitButton() {
        let staged = changes.contains { $0.staged && !$0.conflicted }
        let branch = info?.current ?? "HEAD"
        placeholder.stringValue = staged || changes.isEmpty ? "Message (⌘↩ to commit on “\(branch)”)" : "Message (⌘↩ to commit all changes on “\(branch)”)"
        commitButton?.isEnabled = !busy && !changes.isEmpty && !message.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: data

    func bind(_ wid: String?) {
        guard wid != worktreeId else { return }
        worktreeId = wid; changes = []; info = nil; commits = []; commitFiles = [:]; openCommits = []; limit = 200
        message.string = ""; messageChanged()
        watcher = AppModel.shared.worktree(wid).flatMap { w in FileWatcher(root: w.path) { [weak self] _ in self?.scheduleReload() } }
        rebuild(); reloadAll()
    }

    private func scheduleReload() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reloadAll() }
        pending = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func reloadAll() {
        guard let wid = worktreeId, let c = AppModel.shared.client else { return }
        let id = JSONValue.obj(["id": .string(wid)])
        Task {
            do {
                let ch = try await c.call("git.status", id, as: [FileChange].self)
                let br = try await c.call("git.branches", id, as: BranchInfo.self)
                let graphStale = br.head != info?.head || br.local != info?.local || br.remote != info?.remote || br.current != info?.current
                let changed = ch != changes || br != info
                changes = ch; info = br; showError(nil)
                updateHeader(); updateCommitButton()
                if graphStale || commits.isEmpty { await loadGraph() } else if changed { rebuild() }
            } catch {
                changes = []; info = nil; commits = []
                showError((error as? RPCError)?.message ?? "\(error)")
                updateHeader(); rebuild()
            }
            NotificationCenter.default.post(name: .krillGitChanged, object: wid)
        }
    }

    /// Nothing git can show here: say why instead of an empty commit box.
    private func showError(_ message: String?) {
        for v in [commitArea, separator, moreButton] { v?.isHidden = message != nil }
        outline.enclosingScrollView?.isHidden = message != nil
        empty.isHidden = message == nil
        guard let message else { return }
        let notRepo = message.contains("not a git repository")
        let s = NSMutableAttributedString(string: notRepo ? "Not a Git Repository" : "Git Isn't Available",
                                          attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: "\n" + (notRepo ? "This folder isn't under git version control." : message),
                                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.paragraphSpacing = 4
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        empty.attributedStringValue = s
    }

    private func loadGraph() async {
        guard let wid = worktreeId, let c = AppModel.shared.client else { return }
        if let r = try? await c.call("git.graph", .obj(["id": .string(wid), "limit": .int(limit)])),
           let list = Perf.measure("graph decode", { try? r["commits"]?.decode([GraphCommit].self) }) {
            commits = list; more = r["more"]?.bool == true
            let lanes = list.map { c in ([c.lane] + c.top.flatMap { $0 } + c.bottom.flatMap { $0 }).max() ?? 0 }.max() ?? 0
            graphWidth = GraphView.width(lanes: min(lanes + 1, GraphView.maxLanes))
        }
        loadingMore = false
        Perf.measure("graph rows") { rebuild() }
    }

    private func updateHeader() {
        guard let info else { branchButton.title = ""; syncButton.isHidden = true; return }
        branchButton.title = info.current ?? "Detached at \(info.head ?? "?")"
        if info.merging { branchButton.title += " (Merging)" }
        if let up = info.upstream {
            syncButton.isHidden = false; syncButton.image = .symbol("arrow.triangle.2.circlepath", "Sync")
            syncButton.title = "\(info.behind ?? 0)↓ \(info.ahead ?? 0)↑"; syncButton.toolTip = "Pull from and push to \(up)"
        } else if info.current != nil, !info.remote.isEmpty {
            syncButton.isHidden = false; syncButton.image = .symbol("icloud.and.arrow.up", "Publish Branch")
            syncButton.title = ""; syncButton.toolTip = "Publish Branch"
        } else { syncButton.isHidden = true }
    }

    // MARK: tree

    private func rebuild() {
        var out: [Node] = []
        func section(_ s: Section, _ files: [FileChange]) {
            guard !files.isEmpty else { return }
            let n = Node(.section(s)); n.children = files.map { Node(.file($0, s)) }; out.append(n)
        }
        section(.merge, changes.filter(\.conflicted))
        section(.staged, changes.filter { $0.staged && !$0.conflicted })
        section(.changes, changes.filter { ($0.unstaged || $0.untracked) && !$0.conflicted })
        if changes.isEmpty, info != nil { out.append(Node(.note("No changes"))) }
        if !commits.isEmpty {
            let g = Node(.section(.graph))
            g.children = commits.indices.map { i in
                let n = Node(.commit(i))
                n.children = (commitFiles[commits[i].hash] ?? []).map { Node(.commitFile(commits[i].hash, $0)) }
                return n
            }
            out.append(g)
        }
        roots = out
        outline.reloadData()
        for n in roots {
            guard case .section(let s) = n.kind, !collapsed.contains(s.rawValue) else { continue }
            outline.expandItem(n)
            if s == .graph { for c in n.children { if case .commit(let i) = c.kind, openCommits.contains(commits[i].hash) { outline.expandItem(c) } } }
        }
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[i] ?? roots[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as? Node)?.kind {
        case .section?, .note?: 26
        default: 22
        }
    }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if case .note? = (item as? Node)?.kind { return false }
        return true
    }
    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { HoverRowView() }

    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        switch n.kind {
        case .section(let s):
            let count = s == .graph ? nil : n.children.count
            return SectionCell(title: s.rawValue, count: count, expanded: outline.isItemExpanded(n), actions: sectionActions(s, n))
        case .file(let f, let s):
            return FileCell(f, letter: Self.letter(f, s), indent: 16, actions: fileActions(f, s))
        case .commit(let i):
            if more, !loadingMore, i >= commits.count - 30 { loadMore() }
            let c = commits[i]
            return CommitCell(c, graphWidth: graphWidth, isHead: c.hash.hasPrefix(info?.head ?? "\u{0}"))
        case .commitFile(let h, let f):
            let cell = FileCell(f, letter: Self.letter(f, .graph), indent: graphWidth + 4, actions: [])
            // The lanes below the commit run on through its expanded files, as in VS Code.
            let g = GraphView(); g.through = Array(Set(commits.first { $0.hash == h }?.bottom.compactMap(\.last) ?? []))
            g.frame = NSRect(x: 6, y: 0, width: graphWidth, height: 22); g.autoresizingMask = [.height]
            cell.addSubview(g)
            return cell
        case .note(let t):
            return NoteCell(t)
        }
    }

    func outlineViewItemDidExpand(_ n: Notification) { refreshChevron(n) }
    func outlineViewItemDidCollapse(_ n: Notification) { refreshChevron(n) }
    private func refreshChevron(_ n: Notification) {
        guard let node = n.userInfo?["NSObject"] as? Node, case .section = node.kind else { return }
        let row = outline.row(forItem: node)
        (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionCell)?.expanded = outline.isItemExpanded(node)
    }

    private func loadMore() {
        loadingMore = true; limit += 200
        DispatchQueue.main.async { Task { [weak self] in await self?.loadGraph() } }
    }

    // MARK: clicks

    @objc private func clicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
        switch n.kind {
        case .section(let s):
            if outline.isItemExpanded(n) { outline.collapseItem(n); collapsed.insert(s.rawValue) } else { outline.expandItem(n); collapsed.remove(s.rawValue) }
            UserDefaults.standard.set(Array(collapsed), forKey: "scm.collapsed")
        case .file(let f, let s): open(f, s)
        case .commit(let i): toggle(commit: commits[i].hash)
        case .commitFile(let h, let f): if let w = worktreeId { Workbench.open(DiffTab.uri(w, file: f.path, commit: h)) }
        case .note: break
        }
    }

    private func open(_ f: FileChange, _ s: Section) {
        guard let w = worktreeId else { return }
        if s == .merge { openFile(f); return }
        Workbench.open(DiffTab.uri(w, file: f.path, source: s == .staged ? "staged" : "unstaged"))
    }
    private func openFile(_ f: FileChange) {
        if let w = AppModel.shared.worktree(worktreeId) { Workbench.open(TabURI.file(w.path + "/" + f.path)) }
    }

    private func toggle(commit hash: String) {
        if openCommits.contains(hash) { openCommits.remove(hash); rebuild(); return }
        openCommits.insert(hash)
        guard commitFiles[hash] == nil, let wid = worktreeId else { rebuild(); return }
        Task {
            commitFiles[hash] = (try? await AppModel.shared.client?.call("git.commitFiles", .obj(["id": .string(wid), "commit": .string(hash)]), as: [FileChange].self)) ?? []
            rebuild()
        }
    }

    // MARK: actions

    private func run(_ method: String, _ extra: [String: JSONValue] = [:], done: String? = nil) {
        guard let wid = worktreeId else { return }
        var p = extra; p["id"] = .string(wid)
        busy = true
        Task {
            let ok = await AppModel.shared.call(method, .object(p)) != nil
            busy = false
            if ok, let done { Banner.show(done) }
            reloadAll()
        }
    }

    private func stage(_ files: [FileChange], _ on: Bool) {
        run(on ? "git.stage" : "git.unstage", ["files": .array(files.map { .string($0.path) })])
    }

    private func discard(_ files: [FileChange]) {
        guard !files.isEmpty else { return }
        let a = NSAlert(); a.alertStyle = .warning
        let name = (files[0].path as NSString).lastPathComponent
        if files.count == 1, files[0].untracked {
            a.messageText = "Delete “\(name)”?"; a.informativeText = "Git doesn't track this file, so it can't be restored."
            a.addButton(withTitle: "Delete")
        } else {
            a.messageText = files.count == 1 ? "Discard changes in “\(name)”?" : "Discard all \(files.count) changes?"
            a.informativeText = "This can't be undone." + (files.contains(where: \.untracked) ? " Untracked files are deleted." : "")
            a.addButton(withTitle: "Discard")
        }
        a.addButton(withTitle: "Cancel")
        guard runAsSheet(a) == .alertFirstButtonReturn else { return }
        run("git.discard", ["files": .array(files.map { .string($0.path) })])
    }

    private func sectionActions(_ s: Section, _ n: Node) -> [RowAction] {
        let files = n.children.compactMap { if case .file(let f, _) = $0.kind { f } else { nil } }
        switch s {
        case .merge: return [RowAction("plus", "Stage All (Mark Resolved)") { [weak self] in self?.stage(files, true) }]
        case .staged: return [RowAction("minus", "Unstage All") { [weak self] in self?.stage(files, false) }]
        case .changes: return [RowAction("arrow.uturn.backward", "Discard All Changes") { [weak self] in self?.discard(files) },
                               RowAction("plus", "Stage All Changes") { [weak self] in self?.stage(files, true) }]
        case .graph: return [RowAction("arrow.clockwise", "Refresh") { [weak self] in Task { await self?.loadGraph() } }]
        }
    }

    private func fileActions(_ f: FileChange, _ s: Section) -> [RowAction] {
        var a = [RowAction("doc", "Open File") { [weak self] in self?.openFile(f) }]
        switch s {
        case .staged: a.append(RowAction("minus", "Unstage Changes") { [weak self] in self?.stage([f], false) })
        case .changes:
            a.append(RowAction("arrow.uturn.backward", "Discard Changes") { [weak self] in self?.discard([f]) })
            a.append(RowAction("plus", "Stage Changes") { [weak self] in self?.stage([f], true) })
        case .merge: a.append(RowAction("plus", "Stage (Mark Resolved)") { [weak self] in self?.stage([f], true) })
        case .graph: break
        }
        return a
    }

    @objc private func commitPressed() { commit(push: false, amend: false) }

    private func commit(push: Bool, amend: Bool) {
        let text = message.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let wid = worktreeId, !busy, !text.isEmpty, !changes.isEmpty || amend else { NSSound.beep(); return }
        let all = !changes.contains { $0.staged && !$0.conflicted }
        busy = true
        Task {
            let ok = await AppModel.shared.call("git.commit", .obj(["id": .string(wid), "message": .string(text), "all": .bool(all), "amend": .bool(amend)])) != nil
            if ok { message.string = ""; messageChanged() }
            if ok, push, await AppModel.shared.call("git.push", .obj(["id": .string(wid)])) != nil { Banner.show("Pushed") }
            busy = false
            reloadAll()
        }
    }

    @objc private func draftMessage() {
        guard let wid = worktreeId, let c = AppModel.shared.client else { return }
        generate.isEnabled = false
        Task {
            if let s = try? await c.call("ai.commitMessage", .obj(["id": .string(wid)])).string, !s.isEmpty { message.string = s; messageChanged() }
            else { Banner.show("Couldn't draft a message on this Mac.", style: .error) }
            generate.isEnabled = true
        }
    }

    @objc private func sync() {
        guard let info else { return }
        if info.upstream == nil { run("git.remote", ["op": "push"], done: "Published \(info.current ?? "branch")"); return }
        guard let wid = worktreeId else { return }
        busy = true
        Task {
            if await AppModel.shared.call("git.remote", .obj(["id": .string(wid), "op": "pull"])) != nil {
                if (info.ahead ?? 0) > 0 { _ = await AppModel.shared.call("git.remote", .obj(["id": .string(wid), "op": "push"])) }
            }
            busy = false; reloadAll()
        }
    }

    @objc private func branchMenu() {
        guard let info else { return }
        let m = NSMenu()
        for b in info.local {
            let i = m.add(b) { [weak self] in self?.run("git.switch", ["branch": .string(b)]) }
            i.state = b == info.current ? .on : .off
        }
        if !info.remote.isEmpty {
            let sub = NSMenu()
            for b in info.remote { sub.add(b) { [weak self] in self?.run("git.switch", ["branch": .string(b), "remote": true]) } }
            m.addItem(.separator())
            let r = m.addItem(withTitle: "Remote Branches", action: nil, keyEquivalent: ""); r.submenu = sub
        }
        m.addItem(.separator())
        m.add("Create Branch…") { [weak self] in
            guard let name = prompt("Create Branch", "Starts from \(info.current ?? "HEAD") and switches to it."), !name.isEmpty else { return }
            self?.run("git.switch", ["branch": .string(name), "create": true])
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: branchButton.bounds.height + 4), in: branchButton)
    }

    private func showMoreMenu() {
        guard let wid = worktreeId else { return }
        let m = NSMenu()
        m.add("Pull") { [weak self] in self?.run("git.remote", ["op": "pull"], done: "Pulled") }
        m.add("Push") { [weak self] in self?.run("git.remote", ["op": "push"], done: "Pushed") }
        m.add("Fetch") { [weak self] in self?.run("git.remote", ["op": "fetch"]) }
        m.addItem(.separator())
        m.add("Stash Changes") { [weak self] in self?.run("git.stash", done: "Changes stashed") }
        m.add("Pop Stash") { [weak self] in self?.run("git.stash", ["pop": true]) }
        m.addItem(.separator())
        m.add("Open All Changes") { Workbench.open(DiffTab.uri(wid)) }
        m.add("Create Pull Request…") { PRActions.create(worktree: wid) }
        if let w = AppModel.shared.worktree(wid), let r = AppModel.shared.repo(w.repoId), w.path != r.path {
            m.add("Merge into \(r.baseBranch)…") { [weak self] in self?.mergeIntoBase() }
        }
        let anchor: NSView = moreButton ?? view
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    /// A workspace on its own branch (worktree) into the project's base branch.
    private func mergeIntoBase() {
        guard let wid = worktreeId else { return }
        Task {
            guard let r = await AppModel.shared.call("git.merge", .obj(["id": .string(wid)])) else { return }
            if r["merged"]?.bool == true { Banner.show("Merged"); NotificationCenter.default.post(name: .krillRefresh, object: nil); return }
            let a = NSAlert(); a.messageText = "Merge Conflicts"; a.alertStyle = .warning
            a.informativeText = ((r["conflicts"]?.array ?? []).compactMap(\.string)).joined(separator: "\n") + "\n\nThe merge was aborted; nothing changed."
            _ = await runSheet(a)
        }
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
        switch n.kind {
        case .file(let f, let s):
            if s != .merge { menu.add("Open Changes") { [weak self] in self?.open(f, s) } }
            menu.add("Open File") { [weak self] in self?.openFile(f) }
            menu.addItem(.separator())
            for a in fileActions(f, s).dropFirst() { menu.add(a.title) { a.run() } }
            menu.addItem(.separator())
            menu.add("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(f.path, forType: .string) }
        case .commit(let i):
            let c = commits[i]
            menu.add("Copy Commit Hash") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.hash, forType: .string) }
            menu.add("Copy Commit Message") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.subject, forType: .string) }
        case .commitFile(let h, let f):
            menu.add("Open Changes") { [weak self] in if let w = self?.worktreeId { Workbench.open(DiffTab.uri(w, file: f.path, commit: h)) } }
            menu.add("Open File") { [weak self] in self?.openFile(f) }
        default: break
        }
    }

    // MARK: status letters (VS Code's colors)

    static func letter(_ f: FileChange, _ s: Section) -> (String, NSColor) {
        if s == .merge || f.conflicted { return ("!", .systemRed) }
        if f.untracked { return ("U", .systemGreen) }
        switch s == .changes ? f.worktree : f.index {
        case "A": return ("A", .systemGreen)
        case "D": return ("D", .systemRed)
        case "R": return ("R", .systemBlue)
        case "C": return ("C", .systemBlue)
        default: return ("M", .systemOrange)
        }
    }
}

// MARK: - cells

struct RowAction {
    let symbol: String, title: String, run: @MainActor () -> Void
    init(_ symbol: String, _ title: String, _ run: @escaping @MainActor () -> Void) { self.symbol = symbol; self.title = title; self.run = run }
}

/// Rows that show buttons while the pointer is over them (VS Code's inline actions).
@MainActor
protocol Hoverable: AnyObject { func setHover(_ on: Bool) }

/// Rounded selection inset from the edges, and hover tracking for the cell.
final class HoverRowView: NSTableRowView {
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with e: NSEvent) { (subviews.first as? Hoverable)?.setHover(true) }
    override func mouseExited(with e: NSEvent) { (subviews.first as? Hoverable)?.setHover(false) }
    override func drawSelection(in r: NSRect) {
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

private func actionButtons(_ actions: [RowAction]) -> NSStackView {
    let s = NSStackView(views: actions.map { a in
        let b = ClosureButton(title: "") { a.run() }
        b.image = .symbol(a.symbol, a.title); b.isBordered = false; b.toolTip = a.title
        b.symbolConfiguration = .init(pointSize: 11, weight: .medium); b.contentTintColor = .secondaryLabelColor
        b.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    })
    s.spacing = 2; s.isHidden = true
    return s
}

private func pinRow(_ cell: NSView, _ views: [NSView], leading: CGFloat, trailing: CGFloat = 10) {
    let row = NSStackView(views: views); row.spacing = 5; row.alignment = .centerY
    row.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(row)
    NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
                                 row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -trailing),
                                 row.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
}

final class SectionCell: NSTableCellView, Hoverable {
    private let chevron = NSImageView()
    private let actions: NSStackView
    var expanded = true { didSet { showChevron() } }
    private func showChevron() { chevron.image = .symbol(expanded ? "chevron.down" : "chevron.right") }
    init(title: String, count: Int?, expanded: Bool, actions a: [RowAction]) {
        actions = actionButtons(a)
        super.init(frame: .zero)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold); chevron.contentTintColor = .tertiaryLabelColor
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
        let t = NSTextField(labelWithString: title); t.font = .systemFont(ofSize: 11, weight: .semibold); t.textColor = .secondaryLabelColor
        let c = NSTextField(labelWithString: count.map(String.init) ?? ""); c.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        c.textColor = .secondaryLabelColor
        pinRow(self, [chevron, t, NSView(), actions, c], leading: 10)
        self.expanded = expanded; showChevron()   // didSet doesn't run in init
    }
    required init?(coder: NSCoder) { fatalError() }
    func setHover(_ on: Bool) { actions.isHidden = !on }
}

final class FileCell: NSTableCellView, Hoverable {
    private static var icons: [String: NSImage] = [:]
    private let actions: NSStackView
    init(_ f: FileChange, letter: (String, NSColor), indent: CGFloat, actions a: [RowAction]) {
        actions = actionButtons(a)
        super.init(frame: .zero)
        let ext = (f.path as NSString).pathExtension
        let icon = NSImageView(image: Self.icons[ext] ?? {
            let i = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data); Self.icons[ext] = i; return i
        }())
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true; icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let name = NSTextField(labelWithString: (f.path as NSString).lastPathComponent); name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        if letter.0 == "D" { name.attributedStringValue = NSAttributedString(string: name.stringValue, attributes: [.strikethroughStyle: 1, .font: NSFont.systemFont(ofSize: 12)]) }
        let dir = NSTextField(labelWithString: (f.path as NSString).deletingLastPathComponent); dir.font = .systemFont(ofSize: 11)
        dir.textColor = .tertiaryLabelColor; dir.lineBreakMode = .byTruncatingHead
        dir.setContentCompressionResistancePriority(.init(200), for: .horizontal); name.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        let l = NSTextField(labelWithString: letter.0); l.font = .monospacedSystemFont(ofSize: 11, weight: .semibold); l.textColor = letter.1
        l.alignment = .center; l.widthAnchor.constraint(equalToConstant: 12).isActive = true
        pinRow(self, [icon, name, dir, NSView(), actions, l], leading: indent + 10)
        toolTip = f.path
    }
    required init?(coder: NSCoder) { fatalError() }
    func setHover(_ on: Bool) { actions.isHidden = !on }
}

final class NoteCell: NSTableCellView {
    init(_ text: String) {
        super.init(frame: .zero)
        let t = NSTextField(labelWithString: text); t.font = .systemFont(ofSize: 12); t.textColor = .tertiaryLabelColor
        pinRow(self, [t], leading: 26)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class CommitCell: NSTableCellView {
    init(_ c: GraphCommit, graphWidth: CGFloat, isHead: Bool) {
        super.init(frame: .zero)
        let g = GraphView(); g.commit = c; g.isHead = isHead
        g.translatesAutoresizingMaskIntoConstraints = false; addSubview(g)
        let subject = NSTextField(labelWithString: c.subject); subject.font = .systemFont(ofSize: 12, weight: isHead ? .semibold : .regular)
        subject.lineBreakMode = .byTruncatingTail; subject.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let badges = Self.badges(c.refs)
        let date = NSTextField(labelWithString: Self.relative(c.date)); date.font = .systemFont(ofSize: 11); date.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [subject] + badges + [NSView(), date]); row.spacing = 5; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            g.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), g.topAnchor.constraint(equalTo: topAnchor),
            g.bottomAnchor.constraint(equalTo: bottomAnchor), g.widthAnchor.constraint(equalToConstant: graphWidth),
            row.leadingAnchor.constraint(equalTo: g.trailingAnchor, constant: 2), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        let when = Date(timeIntervalSince1970: c.date).formatted(date: .abbreviated, time: .shortened)
        toolTip = "\(c.subject)\n\n\(c.author) · \(when)\n\(c.hash.prefix(10))" + (c.refs.isEmpty ? "" : "\n" + c.refs.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Local branches and tags (HEAD's branch first); a remote ref shows only when no local branch of that name is here.
    static func badges(_ refs: [String]) -> [NSView] {
        var out: [(String, NSColor, Bool)] = []
        let locals = Set(refs.compactMap { r -> String? in
            if r.hasPrefix("HEAD -> ") { return String(r.dropFirst(8)) }
            return r.hasPrefix("tag: ") || r.contains("/") || r == "HEAD" ? nil : r
        })
        for r in refs {
            if r.hasPrefix("HEAD -> ") { out.insert((String(r.dropFirst(8)), .controlAccentColor, true), at: 0) }
            else if r == "HEAD" { out.insert(("HEAD", .controlAccentColor, true), at: 0) }
            else if r.hasPrefix("tag: ") { out.append((String(r.dropFirst(5)), .systemOrange, false)) }
            else if r.contains("/") { if !locals.contains(String(r.drop { $0 != "/" }.dropFirst())) { out.append((r, .secondaryLabelColor, false)) } }
            else { out.append((r, .controlAccentColor, false)) }
        }
        var views: [NSView] = out.prefix(2).map { Badge(text: $0.0, color: $0.1, strong: $0.2) }
        if out.count > 2 { views.append(Badge(text: "+\(out.count - 2)", color: .secondaryLabelColor, strong: false)) }
        return views
    }

    static func relative(_ t: Double) -> String {
        let s = Date().timeIntervalSince1970 - t
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86400: return "\(Int(s / 3600))h"
        case ..<(86400 * 7): return "\(Int(s / 86400))d"
        default:
            let d = Date(timeIntervalSince1970: t)
            let sameYear = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
            return sameYear ? d.formatted(.dateTime.month(.abbreviated).day()) : d.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}

/// A small rounded label for a branch or tag.
final class Badge: NSView {
    private let text: NSAttributedString
    private let color: NSColor
    init(text: String, color: NSColor, strong: Bool) {
        self.color = color
        self.text = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: strong ? .semibold : .medium),
                                                                   .foregroundColor: color])
        super.init(frame: .zero)
        setContentCompressionResistancePriority(.init(300), for: .horizontal)
        toolTip = text
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: min(ceil(text.size().width) + 10, 110), height: 16) }
    override func draw(_ r: NSRect) {
        color.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let w = bounds.width - 10
        text.draw(with: NSRect(x: 5, y: (bounds.height - text.size().height) / 2, width: w, height: text.size().height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// One row of the history graph: lines from the row above to the dot, from the dot to the row below.
final class GraphView: NSView {
    static let maxLanes = 6
    static let step: CGFloat = 11, inset: CGFloat = 7
    static let colors: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemTeal, .systemPink, .systemGreen, .systemIndigo, .systemBrown]
    static func width(lanes: Int) -> CGFloat { inset * 2 + CGFloat(max(lanes, 1) - 1) * step }
    static func x(_ lane: Int) -> CGFloat { inset + CGFloat(lane) * step }
    static func color(_ lane: Int) -> NSColor { colors[lane % colors.count] }

    var commit: GraphCommit?
    var isHead = false
    /// Under an expanded commit: just these lanes, straight down.
    var through: [Int]?
    override var isFlipped: Bool { true }

    override func draw(_ r: NSRect) {
        if let through {
            for l in through {
                let p = NSBezierPath(); p.move(to: NSPoint(x: Self.x(l), y: 0)); p.line(to: NSPoint(x: Self.x(l), y: bounds.height))
                p.lineWidth = 1.5; Self.color(l).setStroke(); p.stroke()
            }
            return
        }
        guard let c = commit else { return }
        let mid = bounds.height / 2
        func segment(_ l: [Int], from y0: CGFloat, to y1: CGFloat, color: NSColor) {
            guard l.count == 2 else { return }
            let x0 = Self.x(l[0]), x1 = Self.x(l[1]), p = NSBezierPath()
            p.move(to: NSPoint(x: x0, y: y0))
            if x0 == x1 { p.line(to: NSPoint(x: x1, y: y1)) }
            else { p.curve(to: NSPoint(x: x1, y: y1), controlPoint1: NSPoint(x: x0, y: (y0 + y1) / 2), controlPoint2: NSPoint(x: x1, y: (y0 + y1) / 2)) }
            p.lineWidth = 1.5; color.setStroke(); p.stroke()
        }
        for l in c.top { segment(l, from: 0, to: mid, color: Self.color(l[0])) }
        for l in c.bottom { segment(l, from: mid, to: bounds.height, color: Self.color(l.count == 2 ? l[1] : c.lane)) }
        let x = Self.x(c.lane), col = Self.color(c.lane)
        if isHead {
            let ring = NSBezierPath(ovalIn: NSRect(x: x - 4.5, y: mid - 4.5, width: 9, height: 9))
            NSColor.windowBackgroundColor.setFill(); ring.fill()
            ring.lineWidth = 2; col.setStroke(); ring.stroke()
        } else {
            col.setFill(); NSBezierPath(ovalIn: NSRect(x: x - 3.5, y: mid - 3.5, width: 7, height: 7)).fill()
        }
    }
}

/// The commit message: ⌘↩ commits, like VS Code.
final class CommitTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onChange: (() -> Void)?
    private func isCommitKey(_ e: NSEvent) -> Bool { (e.keyCode == 36 || e.keyCode == 76) && e.modifierFlags.contains(.command) }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder === self, isCommitKey(e) { onCommit?(); return true }
        return super.performKeyEquivalent(with: e)
    }
    override func keyDown(with e: NSEvent) { if isCommitKey(e) { onCommit?() } else { super.keyDown(with: e) } }
    override func didChangeText() { super.didChangeText(); onChange?() }
}

/// The message field's rounded border; AppKit calls `updateLayer` again on every light / dark change.
private final class FieldBox: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 6; layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor; layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}
