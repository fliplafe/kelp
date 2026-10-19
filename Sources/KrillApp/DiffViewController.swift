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

/// Diffs the way VS Code shows them: side by side (or inline), whole-line red / green, the changed words darker,
/// hatching where one side has no line. One file (from Source Control) or every change with review comments for the agent.
@MainActor
final class DiffViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let source = NSPopUpButton()
    private let layoutToggle = NSSegmentedControl(images: [.symbol("rectangle.split.2x1", String(localized: "Side by Side")), .symbol("rectangle", String(localized: "Inline"))],
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let files = NSTableView()
    private let table = DiffTable()
    private let status = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private var diffs: [FileDiff] = []
    private var rows: [UIRow] = []
    private var comments: [DiffComment] = []
    private var changes: [FileChange] = []
    /// Changed character range of a line that has a counterpart on the other side, by "file:kind:line".
    private var words: [String: NSRange] = [:]
    private var worktreeId: String?
    private var commitHash: String?
    /// One-file mode: (path, "unstaged" | "staged", commit).
    private var single: (file: String, source: String, commit: String?)?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Side by side when chosen and there's room for two columns; a narrow pane shows it inline (like VS Code).
    private var sideBySide: Bool { layoutToggle.selectedSegment == 0 && !narrow }
    private var narrow = false
    var currentSession: () -> String? = { nil }

    private static let addTint = NSColor.systemGreen.withAlphaComponent(0.14), delTint = NSColor.systemRed.withAlphaComponent(0.14)
    private static let addWord = NSColor.systemGreen.withAlphaComponent(0.32), delWord = NSColor.systemRed.withAlphaComponent(0.32)
    private static let hatch = NSColor(patternImage: NSImage(size: NSSize(width: 7, height: 7), flipped: false) { _ in
        NSColor.secondaryLabelColor.withAlphaComponent(0.14).setStroke()
        let p = NSBezierPath(); p.move(to: .zero); p.line(to: NSPoint(x: 7, y: 7)); p.lineWidth = 1; p.stroke(); return true
    })

    override func loadView() {
        layoutToggle.selectedSegment = UserDefaults.standard.bool(forKey: "diff.inline") ? 1 : 0
        layoutToggle.target = self; layoutToggle.action = #selector(layoutChanged)
        layoutToggle.setToolTip(String(localized: "Side by Side"), forSegment: 0); layoutToggle.setToolTip(String(localized: "Inline"), forSegment: 1)
        source.addItems(withTitles: [String(localized: "Uncommitted"), String(localized: "Unstaged"), String(localized: "Staged"), String(localized: "Branch vs base"), String(localized: "Commit…"), String(localized: "Agent's Last Turn")])
        source.lastItem?.toolTip = String(localized: "What changed since the agent's last prompt, even with other agents in the same folder")
        source.target = self; source.action = #selector(sourceChanged); source.controlSize = .small
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead; pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fc = NSTableColumn(identifier: .init("file")); fc.title = String(localized: "Files")
        files.addTableColumn(fc); files.dataSource = self; files.delegate = self; files.rowHeight = 20; files.style = .sourceList
        files.headerView = nil
        fc.resizingMask = .autoresizingMask; files.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle   // rows as wide as the pane
        let fm = NSMenu(); fm.addItem(withTitle: String(localized: "Stage"), action: #selector(stageFile), keyEquivalent: "").target = self
        fm.addItem(withTitle: String(localized: "Unstage"), action: #selector(unstageFile), keyEquivalent: "").target = self
        files.menu = fm
        let fs = NSScrollView(); fs.documentView = files; fs.hasVerticalScroller = true; fs.drawsBackground = false

        table.dataSource = self; table.delegate = self; table.rowHeight = 18; table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.style = .plain
        table.allowsMultipleSelection = true; table.headerView = nil; table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .textBackgroundColor
        table.onKey = { [weak self] e in self?.key(e) ?? false }
        let cm = NSMenu()
        for (t, st) in [(String(localized: "Mark Resolved"), "resolved"), (String(localized: "Reopen"), "open")] { let i = cm.addItem(withTitle: t, action: #selector(setCommentState(_:)), keyEquivalent: ""); i.target = self; i.representedObject = st }
        table.menu = cm
        let ts = NSScrollView(); ts.documentView = table; ts.hasVerticalScroller = true; ts.autohidesScrollers = true
        setColumns()

        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(fs); split.addArrangedSubview(ts)
        fs.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        ts.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        self.split = split; fileList = fs
        bar.orientation = .horizontal; bar.spacing = 8; bar.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        buildBar()
        view = pinned(bar: bar, body: split)
    }

    private let bar = NSStackView()
    private var split: NSSplitView?
    private var fileList: NSView?
    private var positioned = false
    override func viewDidLayout() {
        super.viewDidLayout()
        if single == nil, !positioned, let s = split, s.bounds.width > 400 { positioned = true; s.setPosition(220, ofDividerAt: 0) }
        let n = table.bounds.width > 0 && table.bounds.width < 640
        if n != narrow {
            narrow = n
            layoutToggle.setEnabled(!n, forSegment: 0)
            layoutToggle.setToolTip(n ? String(localized: "Side by Side (needs a wider pane)") : String(localized: "Side by Side"), forSegment: 0)
            setColumns(); rebuildRows()
        }
    }

    private func buildBar() {
        bar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func icon(_ s: String, _ tip: String, _ a: Selector) -> NSButton {
            let b = NSButton(image: .symbol(s, tip), target: self, action: a); b.isBordered = false; b.toolTip = tip; b.contentTintColor = .secondaryLabelColor
            return b
        }
        if single != nil {
            [pathLabel, status, NSView(), icon("chevron.up", String(localized: "Previous Change (⌥↑)"), #selector(prevChange)),
             icon("chevron.down", String(localized: "Next Change (⌥↓)"), #selector(nextChange)), layoutToggle].forEach { bar.addArrangedSubview($0) }
        } else {
            func btn(_ t: String, _ a: Selector) -> NSButton { let b = NSButton(title: t, target: self, action: a); b.bezelStyle = .rounded; b.controlSize = .small; return b }
            [source, layoutToggle, btn(String(localized: "Comment"), #selector(addComment)), btn("Send to Agent", #selector(sendComments)), NSView(), status]
                .forEach { bar.addArrangedSubview($0) }
        }
    }

    private func setColumns() {
        table.tableColumns.forEach(table.removeTableColumn)
        for id in sideBySide ? ["on", "l", "nn", "r"] : ["on", "nn", "t"] {
            let c = NSTableColumn(identifier: .init(id))
            if id == "on" || id == "nn" { c.width = 44; c.resizingMask = [] } else { c.width = 400; c.minWidth = 120; c.resizingMask = .autoresizingMask }
            table.addTableColumn(c)
        }
        table.sizeToFit()
    }

    func show(worktree id: String?) {
        worktreeId = id
        Task { await load() }
    }

    /// One file, VS Code's diff editor: no file list, just this file's changes.
    func showFile(_ path: String, source: String, commit: String?) {
        single = (path, source, commit)
        fileList?.isHidden = true
        let dir = (path as NSString).deletingLastPathComponent
        let s = NSMutableAttributedString(string: (path as NSString).lastPathComponent, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        if !dir.isEmpty { s.append(NSAttributedString(string: "  " + dir, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])) }
        pathLabel.attributedStringValue = s
        buildBar()
    }

    @objc func reload() { Task { await load() } }
    func showLastTurn() { source.selectItem(at: 5) }
    @objc private func sourceChanged() { askCommit = source.indexOfSelectedItem == 4; reload() }
    private var askCommit = false
    @objc private func layoutChanged() {
        UserDefaults.standard.set(!sideBySide, forKey: "diff.inline")
        setColumns(); rebuildRows()
    }

    private func srcParams() -> JSONValue {
        var p: [String: JSONValue] = ["id": .string(worktreeId ?? "")]
        if let s = single {
            p["file"] = .string(s.file)
            if let c = s.commit { p["source"] = "commit"; p["commit"] = .string(c) } else { p["source"] = .string(s.source) }
            return .object(p)
        }
        switch source.indexOfSelectedItem {
        case 1: p["source"] = "unstaged"
        case 2: p["source"] = "staged"
        case 3: p["source"] = "branch"
        case 4: p["source"] = "commit"; p["commit"] = .string(commitHash ?? "HEAD")
        case 5: p["source"] = "turn"; p["session"] = .string(FileActions.targetAgent?.id ?? "")
        default: p["source"] = "all"
        }
        return .object(p)
    }

    func load() async {
        guard let wid = worktreeId else { diffs = []; rows = []; table.reloadData(); files.reloadData(); return }
        if single == nil, source.indexOfSelectedItem == 4, askCommit {
            let log = (try? await AppModel.shared.client?.call("git.log", .obj(["id": .string(wid), "all": true])))?.array ?? []
            let menu = NSMenu()
            for c in log.prefix(30) { let m = menu.addItem(withTitle: "\(c["hash"]?.string ?? "")  \(c["subject"]?.string ?? "")", action: nil, keyEquivalent: ""); m.representedObject = c["hash"]?.string }
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26)); pop.menu = menu
            let a = NSAlert(); a.messageText = String(localized: "Review which commit?"); a.accessoryView = pop; a.addButton(withTitle: String(localized: "Show")); a.addButton(withTitle: String(localized: "Cancel"))
            if runAsSheet(a) == .alertFirstButtonReturn { commitHash = pop.selectedItem?.representedObject as? String } else { source.selectItem(at: 0); commitHash = nil }
        }
        askCommit = false
        if single == nil, source.indexOfSelectedItem == 5, FileActions.targetAgent == nil {
            diffs = []; files.reloadData(); rebuildRows(); status.stringValue = String(localized: "No agent in this workspace"); return
        }
        let r = await AppModel.shared.tryCall("git.diff", srcParams())
        diffs = (try? r.value?.decode([FileDiff].self)) ?? []
        if let e = r.error, single == nil, source.indexOfSelectedItem == 5 { files.reloadData(); rebuildRows(); status.stringValue = e; return }
        if single == nil {
            changes = (try? await AppModel.shared.client?.call("git.status", .obj(["id": .string(wid)]), as: [FileChange].self)) ?? []
            comments = (try? await AppModel.shared.client?.call("comment.list", .obj(["id": .string(wid)]), as: [DiffComment].self)) ?? []
        }
        files.reloadData(); rebuildRows()
        let add = diffs.reduce(0) { $0 + $1.additions }, del = diffs.reduce(0) { $0 + $1.deletions }
        status.stringValue = single != nil ? (diffs.isEmpty ? String(localized: "No changes") : RowBadges.changes(added: add, removed: del).string)
            : "\(diffs.count) files  \(RowBadges.changes(added: add, removed: del).string)  ·  \(comments.filter { $0.state == .open }.count) open comments"
    }

    private func rebuildRows() {
        var out: [UIRow] = []
        for r in DiffRows.build(diffs, sideBySide: sideBySide) {
            if single != nil, case .file = r { continue }   // the bar names the file
            out.append(.diff(r))
            var fi = -1, ln: Int?
            switch r {
            case .line(let f, let l): fi = f; ln = l.newLine ?? l.oldLine
            case .pair(let f, _, let right): fi = f; ln = right?.newLine
            default: break
            }
            if fi >= 0, let ln { for c in comments where c.file == diffs[fi].path && c.endLine == ln && c.state != .resolved { out.append(.comment(c)) } }
        }
        words = [:]
        for (fi, f) in diffs.enumerated() {
            for h in f.hunks {
                for (l, r) in DiffRows.pairs(h.lines) {
                    guard let l, let r, l.kind == .del, r.kind == .add, let o = l.oldLine, let n = r.newLine else { continue }
                    let (a, b) = Self.changedRanges(l.text, r.text)
                    words["\(fi):d:\(o)"] = a; words["\(fi):a:\(n)"] = b
                }
            }
        }
        rows = out
        table.reloadData()
    }

    /// The part of two versions of a line that differs: what's left after the common start and end.
    /// Limit: one range per line, not a word-by-word diff; enough to spot the edit, as VS Code's first pass does.
    static func changedRanges(_ a: String, _ b: String) -> (NSRange, NSRange) {
        let x = Array(a.utf16), y = Array(b.utf16)
        var p = 0
        while p < min(x.count, y.count), x[p] == y[p] { p += 1 }
        var s = 0
        while s < min(x.count, y.count) - p, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        return (NSRange(location: p, length: x.count - p - s), NSRange(location: p, length: y.count - p - s))
    }

    // MARK: table
    func numberOfRows(in t: NSTableView) -> Int { t === files ? diffs.count : rows.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if t === files {
            let d = diffs[row]
            // The same letters and colours as Source Control and Files; a long path loses its middle, not its counts.
            let (letter, color) = changes.first { $0.path == d.path }?.badge ?? (" ", .labelColor)
            let t = NSMutableAttributedString(string: letter + "  ", attributes: [.font: NSFont.ui(10, weight: .bold), .foregroundColor: color])
            t.append(NSAttributedString(string: d.path + "  ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]))
            t.append(RowBadges.changes(added: d.additions, removed: d.deletions))
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingMiddle
            t.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: t.length))
            let v = label("", font: .systemFont(ofSize: 11)); v.attributedStringValue = t
            return v
        }
        let id = col?.identifier.rawValue ?? ""
        let first = id == "t" || id == "l"
        switch rows[row] {
        case .comment(let c):
            guard first else { return label("", font: font) }
            let v = label("💬 \(c.text)  [\(c.state.rawValue)]", font: .systemFont(ofSize: 11, weight: .medium)); v.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.2); v.drawsBackground = true
            return v
        case .diff(let r):
            switch r {
            case .file(let p, let a, let d):
                let v = label(first ? "\(p)   " + RowBadges.changes(added: a, removed: d).string : "", font: .boldSystemFont(ofSize: 12)); v.backgroundColor = .controlBackgroundColor; v.drawsBackground = true; return v
            case .binary(let p): return label(first ? String(localized: "Binary file \(p) not shown") : "", font: font, color: .secondaryLabelColor)
            case .gap(let n): return band(first ? String(localized: "⋯  \(n) unchanged lines") : "")
            case .hunk(let f, let h, let header):
                guard first else { return band("") }
                let stack = NSStackView(); stack.spacing = 6; stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
                stack.wantsLayer = true; stack.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor
                if canStageHunks {
                    let staged = single?.source == "staged" || (single == nil && source.indexOfSelectedItem == 2)
                    // An icon fits the narrow gutter, like VS Code's hunk actions.
                    let b = NSButton(image: .symbol(staged ? "minus.circle" : "plus.circle", staged ? String(localized: "Unstage Hunk") : String(localized: "Stage Hunk")),
                                     target: self, action: #selector(hunkAction(_:)))
                    b.isBordered = false; b.contentTintColor = .secondaryLabelColor; b.toolTip = staged ? String(localized: "Unstage Hunk") : String(localized: "Stage Hunk"); b.tag = f * 10000 + h
                    stack.addArrangedSubview(b)
                }
                stack.addArrangedSubview(label(header, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .tertiaryLabelColor))
                return stack
            case .line(let f, let l):
                switch id {
                case "on": return number(l.oldLine, kind: l.kind)
                case "nn": return number(l.newLine, kind: l.kind)
                default: return codeCell(l, file: f, marker: true)
                }
            case .pair(let f, let l, let r):
                switch id {
                case "on": return l.map { number($0.oldLine, kind: $0.kind) } ?? filler()
                case "nn": return r.map { number($0.newLine, kind: $0.kind) } ?? filler()
                case "l": return l.map { codeCell($0, file: f, marker: false) } ?? filler()
                default: return r.map { codeCell($0, file: f, marker: false) } ?? filler()
                }
            }
        }
    }

    private var canStageHunks: Bool {
        if let s = single { return s.commit == nil }
        return source.indexOfSelectedItem <= 2
    }

    private func ext(_ f: Int) -> String { (diffs[f].path as NSString).pathExtension }

    private func label(_ s: String, font: NSFont, color: NSColor = .labelColor, align: NSTextAlignment = .left) -> NSTextField {
        let t = NSTextField(labelWithString: s); t.font = font; t.textColor = color; t.alignment = align; t.lineBreakMode = .byClipping; return t
    }
    private func tint(_ k: DiffLine.Kind) -> NSColor? { k == .add ? Self.addTint : k == .del ? Self.delTint : nil }
    private func number(_ n: Int?, kind: DiffLine.Kind) -> NSTextField {
        let t = label(n.map(String.init) ?? "", font: font, color: .tertiaryLabelColor, align: .right)
        if let c = tint(kind) { t.drawsBackground = true; t.backgroundColor = c }
        return t
    }
    /// The side of a side-by-side row that has no line: hatched, like VS Code.
    private func filler() -> NSTextField { let t = label("", font: font); t.drawsBackground = true; t.backgroundColor = Self.hatch; return t }
    private func band(_ s: String) -> NSTextField {
        let t = label(s, font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
        t.drawsBackground = true; t.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
        return t
    }
    private func codeCell(_ l: DiffLine, file f: Int, marker: Bool) -> NSTextField {
        let prefix = marker ? (l.kind == .add ? "+ " : l.kind == .del ? "- " : "  ") : " "
        let s = NSMutableAttributedString(attributedString: Highlighter.attributed(prefix + l.text, ext: ext(f), font: font))
        let key = l.kind == .add ? l.newLine.map { "\(f):a:\($0)" } : l.kind == .del ? l.oldLine.map { "\(f):d:\($0)" } : nil
        if let key, let r = words[key], r.length > 0, r.location + r.length <= (l.text as NSString).length {
            s.addAttribute(.backgroundColor, value: l.kind == .add ? Self.addWord : Self.delWord,
                           range: NSRange(location: r.location + (prefix as NSString).length, length: r.length))
        }
        let t = NSTextField(labelWithAttributedString: s)
        t.lineBreakMode = .byClipping; t.toolTip = l.text.count > 120 ? l.text : nil
        if let c = tint(l.kind) { t.drawsBackground = true; t.backgroundColor = c }
        return t
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard (n.object as? NSTableView) === files, files.selectedRow >= 0 else { return }
        let path = diffs[files.selectedRow].path
        if let i = rows.firstIndex(where: { if case .diff(.file(let p, _, _)) = $0 { p == path } else { false } }) { table.scrollRowToVisible(min(i + 40, rows.count - 1)); table.scrollRowToVisible(i) }
    }

    // MARK: keyboard: ⌥↓/⌥↑ changes, ⌥→/⌥← files
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
    @objc private func nextChange() { jump(hunk: 1) }
    @objc private func prevChange() { jump(hunk: -1) }
    private func jump(hunk dir: Int) {
        let idx = rows.indices.filter { if case .diff(.hunk) = rows[$0] { true } else { false } }
        let cur = max(table.selectedRow, dir > 0 ? -1 : rows.count)
        guard let t = dir > 0 ? idx.first(where: { $0 > cur }) : idx.last(where: { $0 < cur }) else { NSSound.beep(); return }
        table.selectRowIndexes([t], byExtendingSelection: false); table.scrollRowToVisible(min(t + 8, rows.count - 1)); table.scrollRowToVisible(t)
    }

    // MARK: actions
    @objc private func hunkAction(_ b: NSButton) {
        guard let wid = worktreeId else { return }
        let f = b.tag / 10000, h = b.tag % 10000
        let staged = single?.source == "staged" || (single == nil && source.indexOfSelectedItem == 2)
        Task {
            await AppModel.shared.call("git.hunk", .obj(["id": .string(wid), "file": .string(diffs[f].path), "hunk": .int(h), "reverse": .bool(staged)]))
            await load()
            NotificationCenter.default.post(name: .krillGitChanged, object: wid)
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
        guard let text = prompt(String(localized: "Comment on \(file):\(first.0)\(first.0 == last.0 ? "" : "-\(last.0)")"), String(localized: "Goes to the agent with the code quote.")), !text.isEmpty else { return }
        Task {
            await AppModel.shared.call("comment.add", .obj(["id": .string(wid), "file": .string(file), "start": .int(first.0), "end": .int(last.0),
                                                           "quote": .string(lines.map(\.1).joined(separator: "\n")), "text": .string(text)]))
            await load()
        }
    }

    @objc private func setCommentState(_ m: NSMenuItem) {
        guard table.clickedRow >= 0, case .comment(let c) = rows[table.clickedRow] else { NSSound.beep(); return }
        Task { await AppModel.shared.call("comment.setState", .obj(["id": .string(c.id), "state": .string(m.representedObject as? String ?? "")])); await load() }
    }

    @objc private func sendComments() {
        guard let wid = worktreeId else { return }
        guard comments.contains(where: { $0.state == .open }) else { status.stringValue = String(localized: "No open comments"); return }
        guard let sid = pickAgentSession(wid) else { return }
        Task {
            let n = await AppModel.shared.call("comment.send", .obj(["id": .string(wid), "session": .string(sid)]))?.int ?? 0
            status.stringValue = String(localized: "Sent \(n) comments to agent"); await load()
        }
    }

    /// The focused session if it is in this worktree, else ask.
    private func pickAgentSession(_ wid: String) -> String? {
        let live = AppModel.shared.sessions.filter { $0.worktreeId == wid && $0.status != .exited }
        if let cur = currentSession(), live.contains(where: { $0.id == cur }) { return cur }
        if live.count == 1 { return live[0].id }
        guard !live.isEmpty else { status.stringValue = String(localized: "No running agent in this worktree"); return nil }
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        for s in live { pop.addItem(withTitle: "\(s.agent ?? "shell") [\(s.id.prefix(6))]"); pop.lastItem?.representedObject = s.id }
        let a = NSAlert(); a.messageText = String(localized: "Send to which agent?"); a.accessoryView = pop; a.addButton(withTitle: String(localized: "Send")); a.addButton(withTitle: String(localized: "Cancel"))
        return runAsSheet(a) == .alertFirstButtonReturn ? pop.selectedItem?.representedObject as? String : nil
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
        body.trailingAnchor.constraint(equalTo: v.trailingAnchor), body.bottomAnchor.constraint(equalTo: v.bottomAnchor)
    ])
    return v
}

extension FileChange {
    /// VS Code's status letter and colour, as Files and the diff's file list show it.
    var badge: (String, NSColor) {
        conflicted ? ("!", .systemRed) : untracked ? ("U", .systemGreen) : (index == "D" || worktree == "D") ? ("D", .systemRed)
            : index == "A" ? ("A", .systemGreen) : ("M", .systemOrange)
    }
}
