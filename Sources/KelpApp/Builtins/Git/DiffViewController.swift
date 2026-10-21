import AppKit
import Core
import WorkbenchKit

final class DiffTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}

/// Diffs the way VS Code shows them: side by side (or inline), whole-line red / green, the changed words darker,
/// hatching where one side has no line. One file (from Source Control) or every change with review comments for the agent.
@MainActor
final class DiffViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let source = NSPopUpButton()
    private let layoutToggle = NSSegmentedControl(images: [.symbol("rectangle.split.2x1", String(localized: "Side by Side")), .symbol("rectangle", String(localized: "Inline"))],
                                                  trackingMode: .selectOne, target: nil, action: nil)
    let files = NSTableView()
    let table = DiffTable()
    let status = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    var diffs: [FileDiff] = []
    var rows: [ReviewRow] = []
    var comments: [DiffComment] = []
    private var changes: [FileChange] = []
    /// Changed character range of a line that has a counterpart on the other side, by "file:kind:line".
    private var words: [String: NSRange] = [:]
    var worktreeId: String?
    private var commitHash: String?
    /// One-file mode: (path, "unstaged" | "staged", commit).
    var single: (file: String, source: String, commit: String?)?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Side by side when chosen and there's room for two columns; a narrow pane shows it inline (like VS Code).
    private var sideBySide: Bool { layoutToggle.selectedSegment == 0 && !narrow }
    private var narrow = false

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
        source.addItems(withTitles: [String(localized: "Uncommitted"), String(localized: "Unstaged"), String(localized: "Staged"),
                                     String(localized: "Branch vs base"), String(localized: "Commit…"), String(localized: "Agent's Last Turn")])
        source.lastItem?.toolTip = String(localized: "What changed since the agent's last prompt, even with other agents in the same folder")
        source.target = self; source.action = #selector(sourceChanged); source.controlSize = .small
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead; pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fc = NSTableColumn(identifier: .init("file")); fc.title = String(localized: "Files")
        files.addTableColumn(fc); files.dataSource = self; files.delegate = self; files.rowHeight = 26; files.style = .sourceList
        files.headerView = nil
        fc.resizingMask = .autoresizingMask; files.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle   // rows as wide as the pane
        let fm = NSMenu(); fm.addItem(withTitle: String(localized: "Stage"), action: #selector(stageFile), keyEquivalent: "").target = self
        fm.addItem(withTitle: String(localized: "Unstage"), action: #selector(unstageFile), keyEquivalent: "").target = self
        files.menu = fm
        let fs = NSScrollView(); fs.documentView = files; fs.hasVerticalScroller = true; fs.drawsBackground = false

        table.dataSource = self; table.delegate = self; table.rowHeight = 18; table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.style = .plain
        table.allowsMultipleSelection = true; table.headerView = nil; table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .textBackgroundColor; table.floatsGroupRows = false
        table.onKey = { [weak self] e in self?.key(e) ?? false }
        let cm = NSMenu()
        for (t, st) in [(String(localized: "Mark Resolved"), "resolved"), (String(localized: "Reopen"), "open")] {
            let i = cm.addItem(withTitle: t, action: #selector(setCommentState(_:)), keyEquivalent: ""); i.target = self; i.representedObject = st
        }
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
        view = stacked(bar, split)
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
            [source, layoutToggle, btn(String(localized: "Comment"), #selector(addComment)), btn(String(localized: "Send to Agent"), #selector(sendComments)), NSView(), status]
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
    /// Git changed while the tab was in the background: it reads the diff again when shown, not on every save meanwhile.
    var stale = false
    override func viewDidAppear() { super.viewDidAppear(); if stale { stale = false; reload() } }
    func showLastTurn() { source.selectItem(at: 5) }
    @objc private func sourceChanged() { askCommit = source.indexOfSelectedItem == 4; reload() }
    private var askCommit = false
    @objc private func layoutChanged() {
        UserDefaults.standard.set(!sideBySide, forKey: "diff.inline")
        setColumns(); rebuildRows()
    }

    private func diffRequest() -> GitDiff {
        let id = worktreeId ?? ""
        if let s = single {
            return s.commit.map { GitDiff(id: id, source: "commit", file: s.file, commit: $0) } ?? GitDiff(id: id, source: s.source, file: s.file)
        }
        switch source.indexOfSelectedItem {
        case 1: return GitDiff(id: id, source: "unstaged")
        case 2: return GitDiff(id: id, source: "staged")
        case 3: return GitDiff(id: id, source: "branch")
        case 4: return GitDiff(id: id, source: "commit", commit: commitHash ?? "HEAD")
        case 5: return GitDiff(id: id, source: "turn", session: FileActions.targetAgent?.id ?? "")
        default: return GitDiff(id: id, source: "all")
        }
    }

    /// Counts loads: an older one that finishes after a newer one (or after the tab moved on) drops its answers.
    private var loads = 0

    func load() async {
        guard let wid = worktreeId else { diffs = []; rows = []; table.reloadData(); files.reloadData(); return }
        loads += 1; let load = loads
        if single == nil, source.indexOfSelectedItem == 4, askCommit {
            askCommit = false   // before asking: a load that starts while the question is up doesn't ask again
            let log = await AppModel.shared.call(GitLog(id: wid, all: true)) ?? []   // the user picked "a commit": a banner if git can't list them
            let menu = NSMenu()
            for c in log.prefix(30) {
                let m = menu.addItem(withTitle: "\(c.hash)  \(c.subject)", action: nil, keyEquivalent: "")
                m.representedObject = c.hash
            }
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26)); pop.menu = menu
            let a = NSAlert(); a.messageText = String(localized: "Review which commit?"); a.accessoryView = pop
            a.addButton(withTitle: String(localized: "Show")); a.addButton(withTitle: String(localized: "Cancel"))
            if await runSheet(a) == .alertFirstButtonReturn { commitHash = pop.selectedItem?.representedObject as? String } else { source.selectItem(at: 0); commitHash = nil }
        }
        askCommit = false
        if single == nil, source.indexOfSelectedItem == 5, FileActions.targetAgent == nil {
            diffs = []; files.reloadData(); rebuildRows(); status.stringValue = String(localized: "No agent in this workspace"); return
        }
        let r = await AppModel.shared.tryCall(diffRequest())
        let d = r.value ?? []
        var ch: [FileChange] = [], cm: [DiffComment] = []
        if single == nil, r.error == nil {   // the files' letters and the comments: the diff above already said what failed
            ch = await AppModel.shared.quiet(GitStatus(id: wid)) ?? []
            cm = await AppModel.shared.quiet(CommentList(id: wid)) ?? []
        }
        // Rows, cell tags and the hunk buttons index `diffs`: they change together, once every answer is in.
        guard load == loads, wid == worktreeId else { return }
        diffs = d; changes = ch; comments = cm
        files.reloadData(); rebuildRows()
        if let e = r.error { status.stringValue = e; return }   // why there's nothing, not "0 files"
        let add = diffs.reduce(0) { $0 + $1.additions }, del = diffs.reduce(0) { $0 + $1.deletions }
        let open = comments.filter { $0.state == .open }.count
        status.stringValue = single != nil ? (diffs.isEmpty ? String(localized: "No changes") : RowBadges.changes(added: add, removed: del).string)
            : String(localized: "\(diffs.count) files") + "  \(RowBadges.changes(added: add, removed: del).string)"
            + (open > 0 ? "  ·  " + String(localized: "\(open) open comments") : "")
    }

    private func rebuildRows() {
        rows = DiffRows.reviewRows(diffs, comments: comments, sideBySide: sideBySide, hideFileRows: single != nil)
        words = DiffRows.changedWords(diffs)
        table.reloadData()
    }

    // MARK: table
    func numberOfRows(in t: NSTableView) -> Int { t === files ? diffs.count : rows.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if t === files {
            let d = diffs[row]
            // The same letters and colours as Source Control and Files; a long path loses its middle, not its counts.
            let (letter, color) = changes.first { $0.path == d.path }?.badge ?? (" ", .labelColor)
            let t = NSMutableAttributedString(string: letter + "  ", attributes: [.font: NSFont.ui(10, weight: .bold), .foregroundColor: color])
            // The name, its counts, then its folder in grey, shown only when all of it fits: a cut folder ("So…") says nothing.
            let dir = (d.path as NSString).deletingLastPathComponent
            t.append(NSAttributedString(string: (d.path as NSString).lastPathComponent + "  ",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
            t.append(RowBadges.changes(added: d.additions, removed: d.deletions))
            let full = NSMutableAttributedString(attributedString: t)
            if !dir.isEmpty {
                full.append(NSAttributedString(string: "  " + dir, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            for s in [t, full] { s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length)) }
            let v = FitLabel(labelWithAttributedString: t); v.full = full; v.short = t; v.toolTip = d.path
            return v
        }
        let id = col?.identifier.rawValue ?? ""
        let first = id == "t" || id == "l" || col == nil   // nil: a hunk header, one view across the row
        switch rows[row] {
        case .comment(let c):
            guard first else { return label("", font: font) }
            let v = label("💬 \(c.text)  [\(c.state.rawValue)]", font: .systemFont(ofSize: 11, weight: .medium))
            v.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.2); v.drawsBackground = true
            return v
        case .diff(let r):
            switch r {
            case .file(let p, let a, let d):
                let v = label(first ? "\(p)   " + RowBadges.changes(added: a, removed: d).string : "", font: .boldSystemFont(ofSize: 12))
                v.backgroundColor = .controlBackgroundColor; v.drawsBackground = true; return v
            case .binary(let p): return label(first ? String(localized: "Binary file \(p) not shown") : "", font: font, color: .secondaryLabelColor)
            case .gap(let n): return band(first ? String(localized: "⋯  \(n) unchanged lines") : "")
            case .hunk(let f, let h, let header):
                guard first else { return band("") }
                let stack = NSStackView(); stack.spacing = 6; stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
                stack.wantsLayer = true; stack.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
                let where_ = label(header, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
                where_.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                stack.addArrangedSubview(where_)
                if canStageHunks(f) {
                    // Named buttons at the hunk's end, as in Xcode's and GitHub Desktop's reviews.
                    let staged = single?.source == "staged" || (single == nil && source.indexOfSelectedItem == 2)
                    func button(_ title: String, _ a: Selector) -> NSButton {
                        let b = NSButton(title: title, target: self, action: a); b.bezelStyle = .push; b.controlSize = .small
                        b.tag = f * 10000 + h; return b
                    }
                    stack.addArrangedSubview(NSView())
                    // Only where the hunks shown are the unstaged diff's, the one Discard works on.
                    let unstaged = single.map { $0.source == "unstaged" && $0.commit == nil } ?? (source.indexOfSelectedItem == 1)
                    if unstaged { stack.addArrangedSubview(button(String(localized: "Discard…"), #selector(discardHunk(_:)))) }
                    stack.addArrangedSubview(button(staged ? String(localized: "Unstage") : String(localized: "Stage"), #selector(hunkAction(_:))))
                }
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

    /// A hunk's header spans both sides, its buttons at the row's end, rather than ending halfway in an empty strip.
    func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool {
        guard t === table, rows.indices.contains(row), case .diff(.hunk) = rows[row] else { return false }
        return true
    }

    /// Hunk buttons only where the hunks shown are the ones git stages: the unstaged or the staged diff, or the uncommitted
    /// one (against HEAD) for a file with nothing staged, whose hunks are the unstaged diff's.
    private func canStageHunks(_ f: Int) -> Bool {
        if let s = single { return s.commit == nil }
        switch source.indexOfSelectedItem {
        case 1, 2: return true
        case 0: return diffs.indices.contains(f) && changes.first { $0.path == diffs[f].path }?.staged != true
        default: return false
        }
    }

    private func ext(_ f: Int) -> String { (diffs[f].path as NSString).pathExtension }

    private func label(_ s: String, font: NSFont, color: NSColor = .labelColor, align: NSTextAlignment = .left) -> NSTextField {
        let t = NSTextField(labelWithString: s); t.font = font; t.textColor = color; t.alignment = align; t.lineBreakMode = .byClipping; return t
    }
    private func tint(_ k: DiffLine.Kind) -> NSColor? { k == .add ? Self.addTint : k == .del ? Self.delTint : nil }
    private func number(_ n: Int?, kind: DiffLine.Kind) -> NSTextField {
        let t = label(n.map(String.init) ?? "", font: font, color: .secondaryLabelColor, align: .right)
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
        if let i = rows.firstIndex(where: { if case .diff(.file(let p, _, _)) = $0 { p == path } else { false } }) {
            table.scrollRowToVisible(min(i + 40, rows.count - 1)); table.scrollRowToVisible(i)
        }
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
}

/// A file-list row: its folder only when the whole of it fits (`full`), else the name and counts alone (`short`).
private final class FitLabel: NSTextField {
    var full = NSAttributedString(), short = NSAttributedString()
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        let s = full.size().width + 6 <= size.width ? full : short
        if !attributedStringValue.isEqual(to: s) { attributedStringValue = s }
    }
}

extension FileChange {
    /// VS Code's status letter and colour, as Files and the diff's file list show it (text shades: they colour names too).
    var badge: (String, NSColor) {
        conflicted ? ("!", .textRed) : untracked ? ("U", .textGreen) : (index == "D" || worktree == "D") ? ("D", .textRed)
            : index == "A" ? ("A", .textGreen) : ("M", .textOrange)
    }
}
