import AppKit
import Core
import GitKit

private enum UIRow {
    case diff(DiffRow)
    case comment(DiffComment)
}

final class DiffTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}

/// Review screen: file list, inline / side-by-side diff, hunk staging, line comments, commit / push / merge.
@MainActor
final class DiffViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let source = NSPopUpButton()
    private let mode = NSSegmentedControl(labels: ["Inline", "Side by side"], trackingMode: .selectOne, target: nil, action: nil)
    private let files = NSTableView()
    private let table = DiffTable()
    private let status = NSTextField(labelWithString: "")
    private var diffs: [FileDiff] = []
    private var rows: [UIRow] = []
    private var comments: [DiffComment] = []
    private var changes: [FileChange] = []
    private var worktreeId: String?
    private var commitHash: String?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var sideBySide: Bool { mode.selectedSegment == 1 }
    var currentSession: () -> String? = { nil }

    override func loadView() {
        let bar = NSStackView(); bar.orientation = .horizontal; bar.spacing = 8; bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        source.addItems(withTitles: ["Uncommitted", "Unstaged", "Staged", "Branch vs base", "Commit…"])
        source.target = self; source.action = #selector(sourceChanged)
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(modeChanged)
        func btn(_ t: String, _ a: Selector) -> NSButton { let b = NSButton(title: t, target: self, action: a); b.bezelStyle = .rounded; b.controlSize = .small; return b }
        [source, mode, btn("Comment", #selector(addComment)), btn("Send to Agent", #selector(sendComments)), NSView(),
         btn("Commit", #selector(commit)), btn("Push", #selector(push)), btn("Create PR", #selector(createPR)), btn("Merge", #selector(merge))].forEach { bar.addArrangedSubview($0) }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        bar.addArrangedSubview(status)

        let fc = NSTableColumn(identifier: .init("file")); fc.title = "Files"
        files.addTableColumn(fc); files.dataSource = self; files.delegate = self; files.rowHeight = 20; files.style = .sourceList
        files.headerView = nil
        let fm = NSMenu(); fm.addItem(withTitle: "Stage", action: #selector(stageFile), keyEquivalent: "").target = self
        fm.addItem(withTitle: "Unstage", action: #selector(unstageFile), keyEquivalent: "").target = self
        files.menu = fm
        let fs = NSScrollView(); fs.documentView = files; fs.hasVerticalScroller = true; fs.drawsBackground = false

        table.dataSource = self; table.delegate = self; table.rowHeight = 17; table.intercellSpacing = .zero; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true; table.headerView = nil; table.usesAlternatingRowBackgroundColors = false
        table.onKey = { [weak self] e in self?.key(e) ?? false }
        let cm = NSMenu()
        for (t, st) in [("Mark Resolved", "resolved"), ("Reopen", "open")] { let i = cm.addItem(withTitle: t, action: #selector(setCommentState(_:)), keyEquivalent: ""); i.target = self; i.representedObject = st }
        table.menu = cm
        let ts = NSScrollView(); ts.documentView = table; ts.hasVerticalScroller = true; ts.hasHorizontalScroller = true
        setColumns()

        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(fs); split.addArrangedSubview(ts)
        fs.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        ts.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        self.split = split
        view = pinned(bar: bar, body: split)
    }

    private var split: NSSplitView?
    private var positioned = false
    override func viewDidLayout() {
        super.viewDidLayout()
        if !positioned, let s = split, s.bounds.width > 400 { positioned = true; s.setPosition(220, ofDividerAt: 0) }
    }

    var debugInfo: String { "rows=\(table.numberOfRows) frame=\(table.frame) scroll=\(table.enclosingScrollView?.frame ?? .zero) files=\(files.enclosingScrollView?.frame ?? .zero) cols=\(table.tableColumns.map(\.width))" }

    private func setColumns() {
        table.tableColumns.forEach(table.removeTableColumn)
        let ids = sideBySide ? ["on", "l", "nn", "r"] : ["on", "nn", "t"]
        for id in ids {
            let c = NSTableColumn(identifier: .init(id))
            c.width = id == "on" || id == "nn" ? 44 : 420; c.minWidth = 30
            table.addTableColumn(c)
        }
    }

    func show(worktree id: String?) {
        worktreeId = id
        Task { await load() }
    }
    @objc func reload() { Task { await load() } }
    @objc private func sourceChanged() { askCommit = source.indexOfSelectedItem == 4; reload() }
    private var askCommit = false
    @objc private func modeChanged() { setColumns(); rebuildRows() }

    private func srcParams() -> JSONValue {
        var p: [String: JSONValue] = ["id": .string(worktreeId ?? "")]
        switch source.indexOfSelectedItem {
        case 1: p["source"] = "unstaged"
        case 2: p["source"] = "staged"
        case 3: p["source"] = "branch"
        case 4: p["source"] = "commit"; p["commit"] = .string(commitHash ?? "HEAD")
        default: p["source"] = "all"
        }
        return .object(p)
    }

    func load() async {
        guard let wid = worktreeId else { diffs = []; rows = []; table.reloadData(); files.reloadData(); return }
        if source.indexOfSelectedItem == 4, askCommit {
            let log = (try? await AppModel.shared.client?.call("git.log", .obj(["id": .string(wid), "all": true])))?.array ?? []
            let menu = NSMenu()
            for c in log.prefix(30) { let m = menu.addItem(withTitle: "\(c["hash"]?.string ?? "")  \(c["subject"]?.string ?? "")", action: nil, keyEquivalent: ""); m.representedObject = c["hash"]?.string }
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26)); pop.menu = menu
            let a = NSAlert(); a.messageText = "Review which commit?"; a.accessoryView = pop; a.addButton(withTitle: "Show"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { commitHash = pop.selectedItem?.representedObject as? String } else { source.selectItem(at: 0); commitHash = nil }
        }
        askCommit = false
        diffs = (try? await AppModel.shared.client?.call("git.diff", srcParams(), as: [FileDiff].self)) ?? []
        changes = (try? await AppModel.shared.client?.call("git.status", .obj(["id": .string(wid)]), as: [FileChange].self)) ?? []
        comments = (try? await AppModel.shared.client?.call("comment.list", .obj(["id": .string(wid)]), as: [DiffComment].self)) ?? []
        files.reloadData(); rebuildRows()
        let add = diffs.reduce(0) { $0 + $1.additions }, del = diffs.reduce(0) { $0 + $1.deletions }
        status.stringValue = "\(diffs.count) files  +\(add) −\(del)  ·  \(comments.filter { $0.state == .open }.count) open comments"
    }

    private func rebuildRows() {
        var out: [UIRow] = []
        for r in DiffRows.build(diffs, sideBySide: sideBySide) {
            out.append(.diff(r))
            var fi = -1, ln: Int? = nil
            switch r {
            case .line(let f, let l): fi = f; ln = l.newLine ?? l.oldLine
            case .pair(let f, _, let right): fi = f; ln = right?.newLine
            default: break
            }
            if fi >= 0, let ln { for c in comments where c.file == diffs[fi].path && c.endLine == ln && c.state != .resolved { out.append(.comment(c)) } }
        }
        rows = out
        table.reloadData()
    }

    // MARK: table
    func numberOfRows(in t: NSTableView) -> Int { t === files ? diffs.count : rows.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if t === files {
            let d = diffs[row]
            let st = changes.first { $0.path == d.path }
            let mark = st.map { $0.conflicted ? "!" : $0.untracked ? "?" : ($0.staged && !$0.unstaged ? "●" : $0.staged ? "◐" : "○") } ?? " "
            return label("\(mark) \(d.path)   +\(d.additions) −\(d.deletions)", font: .systemFont(ofSize: 11))
        }
        let id = col?.identifier.rawValue ?? ""
        switch rows[row] {
        case .comment(let c):
            guard id == "t" || id == "l" else { return label("", font: font) }
            let v = label("💬 \(c.text)  [\(c.state.rawValue)]", font: .systemFont(ofSize: 11, weight: .medium)); v.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.2); v.drawsBackground = true
            return v
        case .diff(let r):
            switch r {
            case .file(let p, let a, let d):
                let v = label(id == "t" || id == "l" ? "\(p)   +\(a) −\(d)" : "", font: .boldSystemFont(ofSize: 12)); v.backgroundColor = .controlBackgroundColor; v.drawsBackground = true; return v
            case .binary(let p): return label(id == "t" || id == "l" ? "Binary file \(p) not shown" : "", font: font)
            case .gap(let n): return label(id == "t" || id == "l" ? "⋯ \(n) unchanged lines" : "", font: font, color: .tertiaryLabelColor)
            case .hunk(let f, let h, let header):
                guard id == "t" || id == "l" else { return label("", font: font) }
                let stack = NSStackView(); stack.spacing = 6
                let staged = source.indexOfSelectedItem == 2
                let b = NSButton(title: staged ? "Unstage hunk" : "Stage hunk", target: self, action: #selector(hunkAction(_:))); b.controlSize = .mini; b.bezelStyle = .inline
                b.tag = f * 10000 + h
                let l = label(header, font: font, color: .systemTeal)
                stack.addArrangedSubview(b); stack.addArrangedSubview(l)
                if source.indexOfSelectedItem == 3 || source.indexOfSelectedItem == 4 { b.isHidden = true }
                return stack
            case .line(let f, let l):
                switch id {
                case "on": return label(l.oldLine.map(String.init) ?? "", font: font, color: .tertiaryLabelColor, align: .right)
                case "nn": return label(l.newLine.map(String.init) ?? "", font: font, color: .tertiaryLabelColor, align: .right)
                default: return codeCell(l, ext: ext(f))
                }
            case .pair(let f, let l, let r):
                switch id {
                case "on": return label(l?.oldLine.map(String.init) ?? "", font: font, color: .tertiaryLabelColor, align: .right)
                case "nn": return label(r?.newLine.map(String.init) ?? "", font: font, color: .tertiaryLabelColor, align: .right)
                case "l": return l.map { codeCell($0, ext: ext(f)) } ?? label("", font: font)
                default: return r.map { codeCell($0, ext: ext(f)) } ?? label("", font: font)
                }
            }
        }
    }
    private func ext(_ f: Int) -> String { (diffs[f].path as NSString).pathExtension }

    private func label(_ s: String, font: NSFont, color: NSColor = .labelColor, align: NSTextAlignment = .left) -> NSTextField {
        let t = NSTextField(labelWithString: s); t.font = font; t.textColor = color; t.alignment = align; t.lineBreakMode = .byClipping; return t
    }
    private func codeCell(_ l: DiffLine, ext: String) -> NSTextField {
        let t = NSTextField(labelWithAttributedString: Highlighter.attributed((l.kind == .add ? "+" : l.kind == .del ? "-" : " ") + l.text, ext: ext, font: font))
        t.lineBreakMode = .byClipping; t.drawsBackground = l.kind != .context
        t.backgroundColor = l.kind == .add ? NSColor.systemGreen.withAlphaComponent(0.18) : NSColor.systemRed.withAlphaComponent(0.18)
        return t
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard (n.object as? NSTableView) === files, files.selectedRow >= 0 else { return }
        let path = diffs[files.selectedRow].path
        if let i = rows.firstIndex(where: { if case .diff(.file(let p, _, _)) = $0 { p == path } else { false } }) { table.scrollRowToVisible(min(i + 40, rows.count - 1)); table.scrollRowToVisible(i) }
    }

    // MARK: keyboard: ⌥↓/⌥↑ hunks, ⌥→/⌥← files
    private func key(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.option) else { return false }
        switch e.keyCode {
        case 125: jump(hunk: 1); return true
        case 126: jump(hunk: -1); return true
        case 124: files.selectRowIndexes([min(files.selectedRow + 1, diffs.count - 1)], byExtendingSelection: false); return true
        case 123: files.selectRowIndexes([max(files.selectedRow - 1, 0)], byExtendingSelection: false); return true
        default: return false
        }
    }
    private func jump(hunk dir: Int) {
        let idx = rows.indices.filter { if case .diff(.hunk) = rows[$0] { true } else { false } }
        let cur = max(table.selectedRow, 0)
        guard let t = dir > 0 ? idx.first(where: { $0 > cur }) : idx.last(where: { $0 < cur }) else { return }
        table.selectRowIndexes([t], byExtendingSelection: false); table.scrollRowToVisible(t)
    }

    // MARK: actions
    @objc private func hunkAction(_ b: NSButton) {
        guard let wid = worktreeId else { return }
        let f = b.tag / 10000, h = b.tag % 10000
        let staged = source.indexOfSelectedItem == 2
        Task {
            await AppModel.shared.call("git.hunk", .obj(["id": .string(wid), "file": .string(diffs[f].path), "hunk": .int(h), "reverse": .bool(staged)]))
            await load()
        }
    }
    private func selectedFilePath() -> String? { files.clickedRow >= 0 ? diffs[files.clickedRow].path : (files.selectedRow >= 0 ? diffs[files.selectedRow].path : nil) }
    @objc private func stageFile() { fileOp("git.stage") }
    @objc private func unstageFile() { fileOp("git.unstage") }
    private func fileOp(_ m: String) {
        guard let wid = worktreeId, let p = selectedFilePath() else { return }
        Task { await AppModel.shared.call(m, .obj(["id": .string(wid), "files": .array([.string(p)])])); await load() }
    }

    @objc private func addComment() {
        guard let wid = worktreeId else { return }
        var lines: [(Int, String)] = []; var file: String?
        for r in table.selectedRowIndexes {
            guard case .diff(let d) = rows[r] else { continue }
            switch d {
            case .line(let f, let l): file = diffs[f].path; if let n = l.newLine ?? l.oldLine { lines.append((n, l.text)) }
            case .pair(let f, let l, let rr): file = diffs[f].path; if let x = rr ?? l, let n = x.newLine ?? x.oldLine { lines.append((n, x.text)) }
            default: break
            }
        }
        guard let file, let first = lines.first, let last = lines.last else { NSSound.beep(); return }
        guard let text = prompt("Comment on \(file):\(first.0)\(first.0 == last.0 ? "" : "-\(last.0)")", "Goes to the agent with the code quote.") , !text.isEmpty else { return }
        Task {
            await AppModel.shared.call("comment.add", .obj(["id": .string(wid), "file": .string(file), "start": .int(first.0), "end": .int(last.0),
                                                           "quote": .string(lines.map(\.1).joined(separator: "\n")), "text": .string(text)]))
            await load()
        }
    }

    @objc private func setCommentState(_ m: NSMenuItem) {
        guard table.clickedRow >= 0, case .comment(let c) = rows[table.clickedRow] else { NSSound.beep(); return }
        Task { await AppModel.shared.call("comment.setState", .obj(["id": .string(c.id), "state": .string(m.representedObject as! String)])); await load() }
    }

    @objc private func sendComments() {
        guard let wid = worktreeId else { return }
        guard comments.contains(where: { $0.state == .open }) else { status.stringValue = "No open comments"; return }
        guard let sid = pickAgentSession(wid) else { return }
        Task {
            let n = await AppModel.shared.call("comment.send", .obj(["id": .string(wid), "session": .string(sid)]))?.int ?? 0
            status.stringValue = "Sent \(n) comments to agent"; await load()
        }
    }

    /// The focused session if it is in this worktree, else ask.
    private func pickAgentSession(_ wid: String) -> String? {
        let live = AppModel.shared.sessions.filter { $0.worktreeId == wid && $0.status != .exited }
        if let cur = currentSession(), live.contains(where: { $0.id == cur }) { return cur }
        if live.count == 1 { return live[0].id }
        guard !live.isEmpty else { status.stringValue = "No running agent in this worktree"; return nil }
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        for s in live { pop.addItem(withTitle: "\(s.agent ?? "shell") [\(s.id.prefix(6))]"); pop.lastItem?.representedObject = s.id }
        let a = NSAlert(); a.messageText = "Send to which agent?"; a.accessoryView = pop; a.addButton(withTitle: "Send"); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn ? pop.selectedItem?.representedObject as? String : nil
    }

    @objc private func commit() {
        guard let wid = worktreeId, let w = view.window else { return }
        let anyStaged = changes.contains(where: \.staged)
        CommitSheet(worktreeId: wid).present(on: w) { [weak self] msg, askAgent in
            guard let self else { return }
            if askAgent { self.runRecipe("commit", vars: [:]); return }
            guard let msg else { return }
            Task {
                do {
                    let h = try await AppModel.shared.client?.call("git.commit", .obj(["id": .string(wid), "message": .string(msg), "all": .bool(!anyStaged)]))
                    self.status.stringValue = "Committed \(h?.string ?? "")"
                } catch { await self.offerFix("fixCommit", title: "Commit failed", error: error) }
                await self.load()
            }
        }
    }

    /// Send an action recipe (prompt template, overridable per repo) to the agent in this worktree.
    func runRecipe(_ name: String, vars: [String: String]) {
        guard let wid = worktreeId, let sid = pickAgentSession(wid) else { return }
        Task {
            var v: [String: JSONValue] = [:]; for (k, x) in vars { v[k] = .string(x) }
            guard let text = await AppModel.shared.call("recipe.render", .obj(["id": .string(wid), "name": .string(name), "vars": .object(v)]))?.string else { return }
            await AppModel.shared.call("session.send", .obj(["id": .string(sid), "text": .string(text)]))
            status.stringValue = "Sent to agent"
        }
    }

    /// A failed git step: show the error and offer to let the agent fix it.
    func offerFix(_ recipe: String, title: String, error: Error) async {
        let msg = (error as? RPCError)?.message ?? "\(error)"
        let a = NSAlert(); a.messageText = title; a.informativeText = String(msg.suffix(1500)); a.alertStyle = .warning
        a.addButton(withTitle: "Fix with Agent"); a.addButton(withTitle: "Close")
        if await runSheet(a) == .alertFirstButtonReturn { runRecipe(recipe, vars: ["error": String(msg.suffix(6000))]) }
    }

    @objc private func push() {
        guard let wid = worktreeId else { return }
        Task {
            do { _ = try await AppModel.shared.client?.call("git.push", .obj(["id": .string(wid)])); status.stringValue = "Pushed" }
            catch { await offerFix("fixPush", title: "Push failed", error: error) }
        }
    }
    @objc private func createPR() {
        guard let wid = worktreeId, let title = prompt("Create pull request", "Title (the body is generated from the branch commits):", initial: AppModel.shared.worktree(wid)?.branch ?? "") else { return }
        Task { if let r = await AppModel.shared.call("github.pr-create", .obj(["worktreeId": .string(wid), "title": .string(title)])) { status.stringValue = "PR: \(r.string ?? r["url"]?.string ?? "created")" } }
    }
    @objc private func merge() {
        guard let wid = worktreeId else { return }
        Task {
            guard let r = await AppModel.shared.call("git.merge", .obj(["id": .string(wid)])) else { return }
            if r["merged"]?.bool == true { status.stringValue = "Merged into base branch"; NotificationCenter.default.post(name: .krillRefresh, object: nil); return }
            let files = (r["conflicts"]?.array ?? []).compactMap(\.string)
            let a = NSAlert(); a.messageText = "Merge conflicts"; a.informativeText = files.joined(separator: "\n") + "\n\nThe merge was aborted; nothing changed."; a.alertStyle = .warning
            a.addButton(withTitle: "Ask Agent to Resolve"); a.addButton(withTitle: "Cancel")
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            runRecipe("resolveConflicts", vars: ["files": files.joined(separator: ", ")])
        }
    }
}

extension Notification.Name { static let krillRefresh = Notification.Name("krill.refresh") }

/// A toolbar row over a body that fills the rest. Used by every mode view.
@MainActor
func pinned(bar: NSView, body: NSView) -> NSView {
    let v = NSView()
    for x in [bar, body] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
    NSLayoutConstraint.activate([
        bar.topAnchor.constraint(equalTo: v.topAnchor), bar.leadingAnchor.constraint(equalTo: v.leadingAnchor), bar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        body.topAnchor.constraint(equalTo: bar.bottomAnchor), body.leadingAnchor.constraint(equalTo: v.leadingAnchor),
        body.trailingAnchor.constraint(equalTo: v.trailingAnchor), body.bottomAnchor.constraint(equalTo: v.bottomAnchor),
    ])
    return v
}
