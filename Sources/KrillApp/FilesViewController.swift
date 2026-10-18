import AppKit
import Core
import GitKit
import EditorKit
import LSPKit
import Markdown

final class FileNode: NSObject {
    let name: String, path: String   // path relative to worktree root
    var children: [FileNode]? = nil  // nil = file
    init(name: String, path: String, dir: Bool) { self.name = name; self.path = path; children = dir ? [] : nil }

    /// Build a sorted tree (folders first) from relative paths.
    static func tree(_ paths: [String]) -> [FileNode] {
        let root = FileNode(name: "", path: "", dir: true)
        var dirs: [String: FileNode] = ["": root]
        for p in paths.sorted() {
            let parts = p.split(separator: "/").map(String.init)
            var parent = root, acc = ""
            for (i, part) in parts.enumerated() {
                acc = acc.isEmpty ? part : acc + "/" + part
                if i == parts.count - 1 { parent.children!.append(FileNode(name: part, path: acc, dir: false)) }
                else if let d = dirs[acc] { parent = d }
                else { let d = FileNode(name: part, path: acc, dir: true); parent.children!.append(d); dirs[acc] = d; parent = d }
            }
        }
        func sort(_ n: FileNode) { n.children?.sort { ($0.children != nil ? 0 : 1, $0.name.lowercased()) < ($1.children != nil ? 0 : 1, $1.name.lowercased()) }; n.children?.forEach(sort) }
        sort(root)
        return root.children ?? []
    }
}

/// An open file: editor + what we last wrote, to tell our saves from the agent's.
@MainActor
final class OpenFile {
    let path: String, url: URL
    let editor: CodeEditor
    var lastSaved: String
    var saveTask: Task<Void, Never>?
    var lspTask: Task<Void, Never>?
    var markdown: MarkdownTab?
    var tabController: NSViewController { markdown ?? editor.controller }
    init(path: String, url: URL, text: String, editable: Bool) {
        self.path = path; self.url = url; lastSaved = text
        editor = CodeEditor(text: text, url: url, editable: editable)
    }
}

/// File tree with git status, editor tabs with autosave, project search, live reload of agent edits.
@MainActor
final class FilesViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate {
    private let outline = NSOutlineView()
    private let results = NSTableView()
    private let search = NSSearchField()
    private let tabs = NSTabView()
    private let leftTabs = NSSegmentedControl(labels: ["Files", "Search"], trackingMode: .selectOne, target: nil, action: nil)
    private var leftScroll = NSScrollView(), resultsScroll = NSScrollView()
    private var nodes: [FileNode] = []
    private var status: [String: FileChange] = [:]
    private var matches: [SearchMatch] = []
    private var open: [OpenFile] = []
    private var watcher: FileWatcher?
    private(set) var worktree: Worktree?
    private var root: String { worktree?.path ?? "/" }
    var currentSession: () -> String? = { nil }
    private var split: NSSplitView?
    private let problems = NSTextField(labelWithString: "")
    private let problemsButton = NSButton(title: "0", target: nil, action: nil)
    private var positioned = false

    override func loadView() {
        let col = NSTableColumn(identifier: .init("f")); outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil; outline.style = .sourceList; outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.doubleAction = #selector(openSelected)
        outline.registerForDraggedTypes([.fileURL]); outline.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        let m = NSMenu()
        for (t, a) in [("Open", #selector(openSelected)), ("New File…", #selector(newFile)), ("New Folder…", #selector(newFolder)),
                       ("New from Template…", #selector(newFromTemplate)), ("Rename…", #selector(rename)), ("Move to Trash", #selector(trash)), ("Reveal in Finder", #selector(reveal)),
                       ("Insert Path into Agent Prompt", #selector(insertPath))] {
            m.addItem(withTitle: t, action: a, keyEquivalent: "").target = self
        }
        outline.menu = m
        leftScroll.documentView = outline; leftScroll.hasVerticalScroller = true; leftScroll.drawsBackground = false

        let rc = NSTableColumn(identifier: .init("r")); results.addTableColumn(rc); results.headerView = nil
        results.dataSource = self; results.delegate = self; results.rowHeight = 34; results.target = self; results.action = #selector(openResult)
        resultsScroll.documentView = results; resultsScroll.hasVerticalScroller = true; resultsScroll.isHidden = true

        search.placeholderString = "Search in worktree"; search.target = self; search.action = #selector(runSearch); search.sendsSearchStringImmediately = false
        leftTabs.selectedSegment = 0; leftTabs.target = self; leftTabs.action = #selector(leftModeChanged)
        let left = NSView()
        for v in [leftTabs, search, leftScroll, resultsScroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; left.addSubview(v) }
        NSLayoutConstraint.activate([
            leftTabs.topAnchor.constraint(equalTo: left.topAnchor, constant: 6), leftTabs.centerXAnchor.constraint(equalTo: left.centerXAnchor),
            search.topAnchor.constraint(equalTo: leftTabs.bottomAnchor, constant: 6), search.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -8),
            leftScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6), leftScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            leftScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor), leftScroll.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            resultsScroll.topAnchor.constraint(equalTo: leftScroll.topAnchor), resultsScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            resultsScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor), resultsScroll.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        tabs.tabViewType = .topTabsBezelBorder; tabs.delegate = self
        problems.font = .systemFont(ofSize: 11); problems.lineBreakMode = .byTruncatingTail; problems.textColor = .secondaryLabelColor
        problemsButton.bezelStyle = .inline; problemsButton.target = self; problemsButton.action = #selector(showProblems)
        problemsButton.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Problems"); problemsButton.imagePosition = .imageLeading
        let right = NSView()
        for v in [tabs, problemsButton, problems] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; right.addSubview(v) }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: right.topAnchor), tabs.leadingAnchor.constraint(equalTo: right.leadingAnchor), tabs.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            tabs.bottomAnchor.constraint(equalTo: problemsButton.topAnchor, constant: -2),
            problemsButton.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 8), problemsButton.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -4),
            problems.leadingAnchor.constraint(equalTo: problemsButton.trailingAnchor, constant: 8), problems.trailingAnchor.constraint(lessThanOrEqualTo: right.trailingAnchor, constant: -8),
            problems.centerYAnchor.constraint(equalTo: problemsButton.centerYAnchor),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        LSPManager.shared.onDiagnostics = { [weak self] _ in self?.updateProblems() }
        let s = NSSplitView(); s.isVertical = true; s.dividerStyle = .thin
        s.addArrangedSubview(left); s.addArrangedSubview(right)
        s.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split = s
        view = s
    }

    override func viewDidLoad() { super.viewDidLoad(); reloadTree() }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !positioned, let s = split, s.bounds.width > 500 { positioned = true; s.setPosition(250, ofDividerAt: 0) }
    }

    func show(worktree id: String?) {
        guard id != worktree?.id else { return }
        saveOpenList()
        open.forEach { flush($0) }
        open = []; tabs.tabViewItems.forEach(tabs.removeTabViewItem)
        worktree = AppModel.shared.worktree(id)
        watcher = worktree.flatMap { w in FileWatcher(root: w.path) { [weak self] paths in self?.diskChanged(paths) } }
        reloadTree()
        for p in UserDefaults.standard.stringArray(forKey: "files.\(id ?? "")") ?? [] { openFile(p) }
    }

    func reloadTree() {
        guard let w = worktree else { nodes = []; outline.reloadData(); return }
        Task {
            let paths = (try? await AppModel.shared.client?.call("files.list", .obj(["id": .string(w.id)]), as: [String].self)) ?? []
            let st = (try? await AppModel.shared.client?.call("git.status", .obj(["id": .string(w.id)]), as: [FileChange].self)) ?? []
            let expanded = Set((0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode).flatMap { outline.isItemExpanded($0) ? $0.path : nil } })
            status = Dictionary(st.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            nodes = FileNode.tree(paths); outline.reloadData()
            func expand(_ ns: [FileNode]) { for n in ns where n.children != nil && expanded.contains(n.path) { outline.expandItem(n); expand(n.children!) } }
            expand(nodes)
        }
    }

    // MARK: disk changes (agents editing files)
    private var treeReload: DispatchWorkItem?
    private func diskChanged(_ abs: [String]) {
        treeReload?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reloadTree() }
        treeReload = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        let changed = Set(abs.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        for f in open where changed.contains(f.url.resolvingSymlinksInPath().path) { reconcile(f) }
    }

    private func reconcile(_ f: OpenFile) {
        guard let disk = try? String(contentsOf: f.url, encoding: .utf8), disk != f.lastSaved else { return }
        if f.editor.text == f.lastSaved {          // no local edits: take the agent's version
            f.editor.setText(disk); f.lastSaved = disk; return
        }
        // Both sides changed: let the user choose, showing what the agent did.
        let a = NSAlert(); a.messageText = "\(f.path) changed on disk"
        a.informativeText = "You and an agent both edited this file. Your unsaved version and the version on disk differ."
        a.addButton(withTitle: "Keep Mine"); a.addButton(withTitle: "Use Disk Version"); a.addButton(withTitle: "Show Diff")
        a.beginSheetModal(for: view.window!) { [weak self] r in
            switch r {
            case .alertFirstButtonReturn: f.lastSaved = disk; self?.save(f)
            case .alertSecondButtonReturn: f.editor.setText(disk); f.lastSaved = disk
            default: self?.showConflictDiff(f, disk: disk)
            }
        }
    }

    private func showConflictDiff(_ f: OpenFile, disk: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("krill-mine-\(UUID().uuidString.prefix(6))-\(f.url.lastPathComponent)")
        try? f.editor.text.write(to: tmp, atomically: true, encoding: .utf8)
        let diff = (try? Git.run(["diff", "--no-index", "--no-color", f.url.path, tmp.path], cwd: root, ok: [0, 1])) ?? ""
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 360)); tv.string = diff.isEmpty ? "(diff unavailable)" : diff
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular); tv.isEditable = false
        let sv = NSScrollView(frame: tv.frame); sv.documentView = tv; sv.hasVerticalScroller = true
        let a = NSAlert(); a.messageText = "Disk version (−) vs yours (+)"; a.accessoryView = sv
        a.addButton(withTitle: "Keep Mine"); a.addButton(withTitle: "Use Disk Version")
        a.beginSheetModal(for: view.window!) { r in
            if r == .alertFirstButtonReturn { f.lastSaved = disk; self.save(f) } else { f.editor.setText(disk); f.lastSaved = disk }
        }
    }

    // MARK: editor tabs
    func openFile(_ rel: String, line: Int? = nil) {
        guard worktree != nil else { return }
        if let f = open.first(where: { $0.path == rel }), let item = tabs.tabViewItems.first(where: { $0.viewController === f.tabController }) {
            tabs.selectTabViewItem(item); if let line { f.editor.goTo(line: line) }; return
        }
        let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
        if Preview.canPreview(url) { openPreview(rel, url); return }
        if url.pathExtension.lowercased() == "ipynb" {
            if let item = previews[rel], tabs.tabViewItems.contains(item) { tabs.selectTabViewItem(item); return }
            let nb = NotebookTab(url: url, path: rel, worktreeId: worktree?.id); nb.currentSession = currentSession
            let item = NSTabViewItem(identifier: "nb:" + rel); item.label = (rel as NSString).lastPathComponent; item.viewController = nb
            previews[rel] = item; tabs.addTabViewItem(item); tabs.selectTabViewItem(item); return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        guard let text = String(data: data, encoding: .utf8) else {
            NSWorkspace.shared.open(url); return   // binary: let the system preview it
        }
        let t0 = Date()
        let f = OpenFile(path: rel, url: url, text: text, editable: size <= CodeEditor.readOnlyLimit)
        defer { if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT"] != nil { print("OPEN \(rel) lines=\(text.split(separator: "\n").count) in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms") } }
        let wid = worktree?.id ?? ""
        f.editor.onChange = { [weak self, weak f] t in
            guard let f else { return }
            self?.scheduleSave(f); self?.lspChange(f, t); f.markdown?.textChanged()
            if let line = f.editor.cursor?.line { Attribution.markHuman(worktree: wid, file: f.path, line: line) }
        }
        f.editor.onSelection = { [weak self] in self?.updateProblems() }
        let rootPath = root, abs = url.path
        Task { [weak f] in
            guard let c = await LSPManager.shared.client(root: rootPath, path: abs), let f else { return }
            c.open(abs, text: f.editor.text)
            f.editor.completionProvider = { line, col in
                ((try? await c.completion(abs, line: line, column: col)) ?? []).map { CodeEditor.Completion(label: $0.label, detail: $0.detail, insert: $0.insert) }
            }
        }
        open.append(f)
        let item = NSTabViewItem(identifier: rel); item.label = (rel as NSString).lastPathComponent + (size > CodeEditor.readOnlyLimit ? " (read-only)" : "")
        item.toolTip = rel
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            let md = MarkdownTab(editor: f.editor, url: url, path: rel); md.currentSession = currentSession
            f.markdown = md; item.viewController = md
        } else {
            item.viewController = f.editor.controller
        }
        f.editor.view.clipsToBounds = true   // the gutter otherwise draws past the tab into the problems bar
        tabs.addTabViewItem(item); tabs.selectTabViewItem(item)
        if let line { DispatchQueue.main.async { f.editor.goTo(line: line) } }
        saveOpenList()
    }

    private func lspChange(_ f: OpenFile, _ text: String) {
        f.lspTask?.cancel()
        let rootPath = root
        f.lspTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let c = await LSPManager.shared.client(root: rootPath, path: f.url.path) else { return }
            c.change(f.url.path, text: text)
        }
    }

    private func updateProblems() {
        guard let f = current else { problemsButton.title = "0"; problems.stringValue = ""; return }
        let d = LSPManager.shared.diagnostics[f.url.path] ?? []
        problemsButton.title = "\(d.filter { $0.severity == 1 }.count) errors, \(d.filter { $0.severity == 2 }.count) warnings"
        let line = f.editor.cursor?.line
        problems.stringValue = (d.first { $0.line == line } ?? d.first).map { "\($0.line):\($0.column)  \($0.message)" } ?? ""
    }

    @objc private func showProblems() {
        guard let f = current else { return }
        let d = LSPManager.shared.diagnostics[f.url.path] ?? []
        guard !d.isEmpty else { return }
        let menu = NSMenu()
        for x in d.prefix(60) {
            let i = menu.addItem(withTitle: "\(x.severity == 1 ? "⛔︎" : "⚠︎") \(x.line):\(x.column)  \(x.message.prefix(120))", action: #selector(jumpProblem(_:)), keyEquivalent: "")
            i.target = self; i.tag = x.line
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: problemsButton.bounds.height), in: problemsButton)
    }
    @objc private func jumpProblem(_ m: NSMenuItem) { current?.editor.goTo(line: m.tag); current?.editor.focus() }

    /// LSP: jump to the definition of the symbol at the cursor (opens other files in a new tab).
    @objc func jumpToDefinition() {
        guard let f = current, let (l, c) = f.editor.cursor else { return }
        let rootPath = root
        Task {
            guard let client = await LSPManager.shared.client(root: rootPath, path: f.url.path),
                  let loc = try? await client.definition(f.url.path, line: l, column: c) else { NSSound.beep(); return }
            let resolvedRoot = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
            let p = URL(fileURLWithPath: loc.path).resolvingSymlinksInPath().path
            if p.hasPrefix(resolvedRoot + "/") { openFile(String(p.dropFirst(resolvedRoot.count + 1)), line: loc.line) }
            else { NSWorkspace.shared.open(URL(fileURLWithPath: loc.path)) }
        }
    }

    /// LSP: type / docs for the symbol at the cursor.
    @objc func showHover() {
        guard let f = current, let (l, c) = f.editor.cursor else { return }
        let rootPath = root
        Task {
            guard let client = await LSPManager.shared.client(root: rootPath, path: f.url.path),
                  let text = try? await client.hover(f.url.path, line: l, column: c), !text.isEmpty else { NSSound.beep(); return }
            let tf = NSTextField(wrappingLabelWithString: text.replacingOccurrences(of: "```swift\n", with: "").replacingOccurrences(of: "```", with: ""))
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular); tf.preferredMaxLayoutWidth = 460; tf.isSelectable = true
            let vc = NSViewController(); let box = NSView(); tf.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(tf)
            NSLayoutConstraint.activate([tf.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), tf.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
                                         tf.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10), tf.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)])
            vc.view = box
            let pop = NSPopover(); pop.contentViewController = vc; pop.behavior = .transient
            pop.show(relativeTo: NSRect(x: f.editor.view.bounds.midX, y: f.editor.view.bounds.maxY - 40, width: 1, height: 1), of: f.editor.view, preferredEdge: .maxY)
        }
    }

    /// Images, PDFs and documents open as read-only preview tabs (no editor, nothing to save).
    private var previews: [String: NSTabViewItem] = [:]
    private func openPreview(_ rel: String, _ url: URL) {
        if let item = previews[rel], tabs.tabViewItems.contains(item) { tabs.selectTabViewItem(item); return }
        let item = NSTabViewItem(identifier: "preview:" + rel); item.label = (rel as NSString).lastPathComponent; item.toolTip = rel
        item.view = Preview.view(for: url)
        previews[rel] = item; tabs.addTabViewItem(item); tabs.selectTabViewItem(item)
    }

    private func scheduleSave(_ f: OpenFile) {
        f.saveTask?.cancel()
        f.saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { self?.save(f) }
        }
    }
    private func save(_ f: OpenFile) {
        let t = f.editor.text
        guard t != f.lastSaved || !FileManager.default.fileExists(atPath: f.url.path) else { return }
        // If the disk moved on since our last save, don't clobber it silently.
        if let disk = try? String(contentsOf: f.url, encoding: .utf8), disk != f.lastSaved { reconcile(f); return }
        do { try t.write(to: f.url, atomically: true, encoding: .utf8); f.lastSaved = t }
        catch { presentError(error) }
    }
    private func flush(_ f: OpenFile) { f.saveTask?.cancel(); save(f) }

    @objc func closeTab() {
        guard let item = tabs.selectedTabViewItem else { return }
        if let key = previews.first(where: { $0.value === item })?.key { previews[key] = nil; tabs.removeTabViewItem(item); return }
        guard let i = open.firstIndex(where: { $0.tabController === item.viewController }) else { return }
        let f = open[i]; flush(f); open.remove(at: i); tabs.removeTabViewItem(item); saveOpenList()
        let rootPath = root; Task { await LSPManager.shared.client(root: rootPath, path: f.url.path)?.close(f.url.path) }
    }
    func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) { updateProblems() }

    private func saveOpenList() {
        guard let id = worktree?.id else { return }
        UserDefaults.standard.set(open.map(\.path), forKey: "files.\(id)")
    }

    var current: OpenFile? { tabs.selectedTabViewItem.flatMap { item in open.first { $0.tabController === item.viewController } } }

    @objc func goToLine() {
        guard let f = current, let s = prompt("Go to line", ""), let n = Int(s) else { return }
        f.editor.goTo(line: n)
    }

    @objc func markdownNote() { current?.markdown?.noteToAgent() }
    @objc func markdownBold() { current?.markdown?.bold() }
    @objc func markdownItalic() { current?.markdown?.italic() }

    /// Selected code → agent prompt (not submitted, so you can add the question).
    @objc func sendSelectionToAgent() {
        guard let f = current, let text = f.editor.selectedText, let sid = currentSession() else { NSSound.beep(); return }
        let lines = f.editor.selectedLines.map { $0.lowerBound == $0.upperBound ? "line \($0.lowerBound)" : "lines \($0.lowerBound)-\($0.upperBound)" } ?? ""
        let msg = "In \(f.path) \(lines):\n```\n\(text)\n```\n"
        Task { await AppModel.shared.call("session.send", .obj(["id": .string(sid), "text": .string(msg), "enter": false])) }
    }

    // MARK: outline
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? FileNode)?.children?.count ?? (item == nil ? nodes.count : 0) }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { (item as? FileNode)?.children?[i] ?? nodes[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.children != nil }
    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? FileNode else { return nil }
        let cell = NSTableCellView(); let tf = NSTextField(labelWithString: n.name); let img = NSImageView()
        img.image = n.children != nil ? NSImage(systemSymbolName: "folder", accessibilityDescription: nil) : NSWorkspace.shared.icon(for: .init(filenameExtension: (n.name as NSString).pathExtension) ?? .data)
        tf.lineBreakMode = .byTruncatingMiddle; tf.font = .systemFont(ofSize: 12)
        let badge = NSTextField(labelWithString: "")
        if let s = status[n.path] {
            let (letter, color): (String, NSColor) = s.conflicted ? ("!", .systemRed) : s.untracked ? ("U", .systemGreen) : (s.index == "D" || s.worktree == "D") ? ("D", .systemRed) : (s.index == "A" ? ("A", .systemGreen) : ("M", .systemOrange))
            badge.stringValue = letter; badge.textColor = color; tf.textColor = color
        } else if n.children != nil, status.keys.contains(where: { $0.hasPrefix(n.path + "/") }) { tf.textColor = .systemOrange }
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        for v in [img, tf, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        cell.textField = tf; cell.imageView = img
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: cell.leadingAnchor), img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 16), img.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 4), tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: tf.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    // drag files out (to terminals = into the agent prompt, to Finder) and within the tree (move)
    func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode).map { URL(fileURLWithPath: root).appendingPathComponent($0.path) as NSURL }
    }
    func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard (item as? FileNode)?.children != nil || item == nil else { return [] }
        return info.draggingSource as? NSOutlineView === outline ? .move : .copy
    }
    func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex: Int) -> Bool {
        let destDir = URL(fileURLWithPath: root).appendingPathComponent((item as? FileNode)?.path ?? "")
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        let move = info.draggingSource as? NSOutlineView === outline
        for u in urls {
            let dst = destDir.appendingPathComponent(u.lastPathComponent)
            do { if move { try FileManager.default.moveItem(at: u, to: dst) } else { try FileManager.default.copyItem(at: u, to: dst) } }
            catch { presentError(error); return false }
        }
        reloadTree(); return true
    }

    private var selectedNode: FileNode? { (outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) : outline.item(atRow: outline.selectedRow)) as? FileNode }
    private var selectedDir: String {
        guard let n = selectedNode else { return "" }
        return n.children != nil ? n.path : (n.path as NSString).deletingLastPathComponent
    }
    @objc private func openSelected() {
        guard let n = selectedNode else { return }
        if n.children != nil { outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n) } else { openFile(n.path) }
    }
    @objc private func newFile() {
        guard let name = prompt("New file", "In /\(selectedDir)"), !name.isEmpty else { return }
        let rel = selectedDir.isEmpty ? name : selectedDir + "/" + name
        let u = URL(fileURLWithPath: root).appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: u.path, contents: Data())
        reloadTree(); openFile(rel)
    }
    /// Markdown templates from <repo>/.krill/templates and ~/.krill/templates with {{date}}, {{branch}}, {{title}}…
    @objc private func newFromTemplate() {
        let repo = AppModel.shared.repo(worktree?.repoId)
        let dirs = [URL(fileURLWithPath: root).appendingPathComponent(".krill/templates"), Paths.root.appendingPathComponent("templates")]
        let all = dirs.flatMap { Templates.list(in: $0) }
        guard !all.isEmpty else {
            let a = NSAlert(); a.messageText = "No templates yet"; a.informativeText = "Add Markdown files to .krill/templates in the repo or ~/.krill/templates. Placeholders: {{date}}, {{time}}, {{branch}}, {{title}}, {{repo}}."
            Task { _ = await runSheet(a) }; return
        }
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26)); for t in all { pop.addItem(withTitle: t.deletingPathExtension().lastPathComponent) }
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); name.placeholderString = "File name, e.g. plan-login.md"
        let box = NSStackView(views: [pop, name]); box.orientation = .vertical; box.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        let a = NSAlert(); a.messageText = "New from Template"; a.accessoryView = box; a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn, !name.stringValue.isEmpty, let text = try? String(contentsOf: all[pop.indexOfSelectedItem], encoding: .utf8) else { return }
            var file = name.stringValue; if (file as NSString).pathExtension.isEmpty { file += ".md" }
            let title = (file as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ")
            let body = Templates.expand(text, vars: ["branch": worktree?.branch ?? "", "title": title, "repo": repo?.name ?? ""])
            let rel = selectedDir.isEmpty ? file : selectedDir + "/" + file
            let u = URL(fileURLWithPath: root).appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try body.write(to: u, atomically: true, encoding: .utf8) } catch { presentError(error); return }
            reloadTree(); openFile(rel)
        }
    }

    @objc private func newFolder() {
        guard let name = prompt("New folder", "In /\(selectedDir)"), !name.isEmpty else { return }
        do { try FileManager.default.createDirectory(at: URL(fileURLWithPath: root).appendingPathComponent(selectedDir).appendingPathComponent(name), withIntermediateDirectories: true) }
        catch { presentError(error) }
        reloadTree()   // empty folders are invisible to git; it appears once it has a file
    }
    @objc private func rename() {
        guard let n = selectedNode, let name = prompt("Rename", n.path, initial: n.name), !name.isEmpty, name != n.name else { return }
        let src = URL(fileURLWithPath: root).appendingPathComponent(n.path)
        do { try FileManager.default.moveItem(at: src, to: src.deletingLastPathComponent().appendingPathComponent(name)) } catch { presentError(error) }
        reloadTree()
    }
    @objc private func trash() {
        guard let n = selectedNode else { return }
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: root).appendingPathComponent(n.path), resultingItemURL: nil) } catch { presentError(error) }
        reloadTree()
    }
    @objc private func reveal() {
        guard let n = selectedNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root).appendingPathComponent(n.path)])
    }
    @objc private func insertPath() {
        guard let n = selectedNode, let sid = currentSession() else { NSSound.beep(); return }
        Task { await AppModel.shared.call("session.send", .obj(["id": .string(sid), "text": .string(n.path + " "), "enter": false])) }
    }
    @objc func openInExternalEditor() {
        guard let f = current else { return }
        flush(f); NSWorkspace.shared.open(f.url)
    }

    // MARK: search
    @objc private func leftModeChanged() { resultsScroll.isHidden = leftTabs.selectedSegment == 0; leftScroll.isHidden = !resultsScroll.isHidden }
    @objc func runSearch() {
        guard let w = worktree else { return }
        let q = search.stringValue
        leftTabs.selectedSegment = 1; leftModeChanged()
        Task {
            matches = (try? await AppModel.shared.client?.call("files.search", .obj(["id": .string(w.id), "query": .string(q)]), as: [SearchMatch].self)) ?? []
            results.reloadData()
        }
    }
    func focusSearch() { view.window?.makeFirstResponder(search) }
    func numberOfRows(in t: NSTableView) -> Int { matches.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let m = matches[row]
        let top = NSTextField(labelWithString: "\(m.path):\(m.line)"); top.font = .systemFont(ofSize: 10); top.textColor = .secondaryLabelColor
        let txt = NSTextField(labelWithString: m.text); txt.font = .monospacedSystemFont(ofSize: 11, weight: .regular); txt.lineBreakMode = .byTruncatingTail
        let s = NSStackView(views: [top, txt]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 1
        return s
    }
    @objc private func openResult() { if results.clickedRow >= 0 { let m = matches[results.clickedRow]; openFile(m.path, line: m.line) } }
}
