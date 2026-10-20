import AppKit
import Core
import Quartz
import GitKit
import Markdown

final class FileNode: NSObject {
    let name: String, path: String   // path relative to worktree root
    var children: [FileNode]?  // nil = file
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
                if i == parts.count - 1 { parent.children?.append(FileNode(name: part, path: acc, dir: false)) }
                else if let d = dirs[acc] { parent = d }
                else { let d = FileNode(name: part, path: acc, dir: true); parent.children?.append(d); dirs[acc] = d; parent = d }
            }
        }
        func sort(_ n: FileNode) { n.children?.sort { ($0.children != nil ? 0 : 1, $0.name.lowercased()) < ($1.children != nil ? 0 : 1, $1.name.lowercased()) }; n.children?.forEach(sort) }
        sort(root)
        return root.children ?? []
    }
}

/// The workspace's files: tree with git status (click opens a tab), file operations, and project search.
@MainActor
final class FilesPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
                        QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let outline = FilesOutline()
    /// The row whose name is being edited in place (a rename, or a new file).
    private var renaming: (field: NSTextField, url: URL, open: Bool)?
    private let results = ResultsTable()
    private let search = NSSearchField()
    private let leftScroll = NSScrollView(), resultsScroll = NSScrollView()
    private var nodes: [FileNode] = []
    private var status: [String: FileChange] = [:]
    private var matches: [SearchMatch] = []
    private var watcher: FileWatcher?
    private var worktree: Worktree?
    private var root: String { worktree?.path ?? "/" }
    private var treeReload: DispatchWorkItem?

    override func loadView() {
        let col = NSTableColumn(identifier: .init("f")); outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil; outline.style = .sourceList; outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.action = #selector(openSelected)
        outline.registerForDraggedTypes([.fileURL]); outline.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        outline.onSpace = { [weak self] in self?.togglePreview() }
        outline.onReturn = { [weak self] in self?.rename() }
        outline.onDelete = { [weak self] in self?.trashSelected() }
        // Grouped like Finder's: open, create, change, locate, hand to the agent.
        let m = NSMenu()
        for group in [[("Open", #selector(openSelected))],
                      [("New File", #selector(newFile)), (String(localized: "New Folder…"), #selector(newFolder)), (String(localized: "New from Template…"), #selector(newFromTemplate))],
                      [("Rename", #selector(rename)), (String(localized: "Move to Trash"), #selector(trashSelected)), (String(localized: "Quick Look"), #selector(togglePreview))],
                      [("Reveal in Finder", #selector(reveal)), ("Copy Path", #selector(copyPath)), (String(localized: "Copy Relative Path"), #selector(copyRelativePath))],
                      [("Send to Agent", #selector(insertPath)), ("Copy Web Link", #selector(copyWebLink))]] {
            if !m.items.isEmpty { m.addItem(.separator()) }
            for (t, a) in group { m.addItem(withTitle: loc(t), action: a, keyEquivalent: "").target = self }
        }
        let openIn = NSMenu()
        WorkspaceActions.addOpenIn(to: openIn, path: { [weak self] in self?.selectedPath }, prefix: "")
        if !openIn.items.isEmpty, let i = m.items.firstIndex(where: { $0.action == #selector(reveal) }) {
            m.insertItem(withTitle: String(localized: "Open In"), action: nil, keyEquivalent: "", at: i + 1).submenu = openIn
        }
        outline.menu = m
        leftScroll.documentView = outline; leftScroll.hasVerticalScroller = true; leftScroll.drawsBackground = false
        let rc = NSTableColumn(identifier: .init("r")); results.addTableColumn(rc); results.headerView = nil; results.style = .sourceList
        results.dataSource = self; results.delegate = self; results.rowHeight = TextSize.of(34); results.target = self; results.action = #selector(openResult)
        search.delegate = self
        // ⇧⌘F (Find in Workspace): straight into this field; pressed again there, back to what you were doing.
        NotificationCenter.default.addObserver(forName: .kelpFindInFiles, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let w = self.view.window else { return }
                if w.firstResponder === self.search.currentEditor() { Workbench.editor?.focusSelected(); return }
                w.makeFirstResponder(self.search); self.search.currentEditor()?.selectAll(nil)
            }
        }
        resultsScroll.documentView = results; resultsScroll.hasVerticalScroller = true; resultsScroll.isHidden = true; resultsScroll.drawsBackground = false
        // One field, like Finder's: empty shows the tree, a search (↩) shows matches in their place, clearing it goes back.
        search.placeholderString = String(localized: "Search in Files"); search.target = self; search.action = #selector(runSearch); search.sendsSearchStringImmediately = false
        search.controlSize = .small
        let v = NSView()
        noMatches.textColor = .secondaryLabelColor; noMatches.alignment = .center
        let clear = ClosureButton(title: String(localized: "Clear Search")) { [weak self] in
            guard let self else { return }
            search.stringValue = ""; runSearch(); view.window?.makeFirstResponder(outline)
        }
        clear.bezelStyle = .push; clear.controlSize = .small
        let empty = NSStackView(views: [noMatches, clear]); empty.orientation = .vertical; empty.spacing = 8; empty.isHidden = true
        noResults = empty
        for x in [search, leftScroll, resultsScroll, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 40),
                                     empty.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -32)])
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: v.topAnchor, constant: 8), search.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            leftScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6), leftScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            leftScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor), leftScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            resultsScroll.topAnchor.constraint(equalTo: leftScroll.topAnchor), resultsScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            resultsScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor), resultsScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        ])
        view = v
        track { Workbench.shared.workspaceId } changed: { [weak self] in self?.bind($0) }
        track { FileIcon.revision } changed: { [weak self] _ in self?.reloadIcons() }
    }

    private func reloadIcons() { outline.reloadData(forRowIndexes: IndexSet(0..<outline.numberOfRows), columnIndexes: [0]) }

    private func bind(_ wid: String?) {
        guard wid != worktree?.id else { return }
        worktree = AppModel.shared.worktree(wid)
        matches = []; results.reloadData()
        watcher = worktree.flatMap { w in FileWatcher(root: w.path) { [weak self] _ in self?.scheduleReload() } }
        reloadTree()
    }

    private func scheduleReload() {
        treeReload?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reloadTree() }
        treeReload = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func reloadTree(then done: (() -> Void)? = nil) {
        guard renaming == nil else { scheduleReload(); return }   // a reload would end the edit
        guard let w = worktree else { nodes = []; outline.reloadData(); return }
        Task {
            let paths = (try? await AppModel.shared.client?.call("files.list", .obj(["id": .string(w.id)]), as: [String].self)) ?? []
            let st = (try? await AppModel.shared.client?.call("git.status", .obj(["id": .string(w.id)]), as: [FileChange].self)) ?? []
            let expanded = Set((0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode).flatMap { outline.isItemExpanded($0) ? $0.path : nil } })
            let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.path
            status = Dictionary(st.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            nodes = FileNode.tree(paths); outline.reloadData()
            func expand(_ ns: [FileNode]) { for n in ns where n.children != nil && expanded.contains(n.path) { outline.expandItem(n); expand(n.children ?? []) } }
            expand(nodes)
            if let selected, let n = node(at: selected) { outline.selectRowIndexes([outline.row(forItem: n)], byExtendingSelection: false) }
            done?()
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        }
    }

    private func openFile(_ rel: String, line: Int? = nil, focus: Bool = true) { Workbench.open(TabURI.file(root + "/" + rel, line: line), focus: focus) }
    private func showError(_ e: Error) { Banner.show(e.localizedDescription) }

    // MARK: outline
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? FileNode)?.children?.count ?? (item == nil ? nodes.count : 0) }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { (item as? FileNode)?.children?[i] ?? nodes[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.children != nil }
    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? FileNode else { return nil }
        let cell = NSTableCellView(); let tf = NSTextField(labelWithString: n.name); let img = NSImageView()
        img.image = FileIcon.image(n.name, folder: n.children != nil, expanded: o.isItemExpanded(n))
        tf.lineBreakMode = .byTruncatingMiddle; tf.font = .ui(12)
        let badge = NSTextField(labelWithString: "")
        if let s = status[n.path] {
            let (letter, color) = s.badge
            badge.stringValue = letter; badge.textColor = color; tf.textColor = color
        } else if n.children != nil, status.keys.contains(where: { $0.hasPrefix(n.path + "/") }) { tf.textColor = .systemOrange }
        badge.font = .ui(10, weight: .bold)
        for v in [img, tf, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        cell.textField = tf; cell.imageView = img
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: cell.leadingAnchor), img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 16), img.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 4), tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: tf.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    // themes may draw open folders differently
    func outlineViewItemDidExpand(_ n: Notification) { reloadRow(of: n) }
    func outlineViewItemDidCollapse(_ n: Notification) { reloadRow(of: n) }
    private func reloadRow(of n: Notification) {
        let row = outline.row(forItem: n.userInfo?["NSObject"])
        if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
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
        if info.draggingSource as? NSOutlineView === outline {
            let pairs = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != destDir.standardizedFileURL }
                .map { ($0, Self.free(destDir.appendingPathComponent($0.lastPathComponent))) }
            return move(pairs, undo: String(localized: "Move"))
        }
        return copy(urls, into: destDir, undo: "Copy")
    }

    // MARK: file operations, each one undoable with ⌘Z (as moves: trashing is a move into the Trash)

    /// Moves each `from → to`; ⌘Z moves them back.
    @discardableResult private func move(_ pairs: [(URL, URL)], undo name: String) -> Bool {
        var done: [(URL, URL)] = []
        for (a, b) in pairs {
            do { try FileManager.default.moveItem(at: a, to: b); done.append((a, b)) } catch { showError(error); break }
        }
        if !done.isEmpty {
            undoManager?.registerUndo(withTarget: self) { $0.move(done.reversed().map { ($0.1, $0.0) }, undo: name) }
            undoManager?.setActionName(name)
        }
        reloadTree(); return done.count == pairs.count
    }

    private func trash(_ urls: [URL], undo name: String) {
        var back: [(URL, URL)] = []
        for u in urls {
            var out: NSURL?
            do { try FileManager.default.trashItem(at: u, resultingItemURL: &out) } catch { showError(error); break }
            if let t = out as URL? { back.append((t, u)) }
        }
        if !back.isEmpty { undoManager?.registerUndo(withTarget: self) { $0.move(back, undo: name) }; undoManager?.setActionName(name) }
        reloadTree()
    }

    /// Copies into `dir`, taking Finder's "name copy" when the name is taken; ⌘Z puts the copies in the Trash.
    @discardableResult private func copy(_ urls: [URL], into dir: URL, undo name: String) -> Bool {
        var made: [URL] = []
        for u in urls {
            let dst = Self.free(dir.appendingPathComponent(u.lastPathComponent))
            do { try FileManager.default.copyItem(at: u, to: dst); made.append(dst) } catch { showError(error); break }
        }
        if !made.isEmpty { undoManager?.registerUndo(withTarget: self) { $0.trash(made, undo: name) }; undoManager?.setActionName(name) }
        reloadTree(); return made.count == urls.count
    }

    /// `u`, or the first of "name copy.ext", "name copy 2.ext"… (`word: nil`: "name 2.ext") that doesn't exist.
    static func free(_ u: URL, word: String? = "copy") -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: u.path) else { return u }
        let ext = u.pathExtension, base = u.deletingPathExtension().lastPathComponent, dir = u.deletingLastPathComponent()
        var i = word == nil ? 2 : 1
        while true {
            let stem = [base, word].compactMap { $0 }.joined(separator: " ") + (i > 1 ? " \(i)" : "")
            let c = dir.appendingPathComponent(ext.isEmpty ? stem : stem + "." + ext)
            if !fm.fileExists(atPath: c.path) { return c }
            i += 1
        }
    }

    /// ⌘C: the file itself, for pasting here, in Finder, or into a terminal (its path).
    @objc func copy(_ sender: Any?) {
        guard let n = selectedNode else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([URL(fileURLWithPath: root).appendingPathComponent(n.path) as NSURL])
    }
    /// ⌘V: files copied here or in Finder, into the selected folder.
    @objc func paste(_ sender: Any?) {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { NSSound.beep(); return }
        copy(urls, into: URL(fileURLWithPath: root).appendingPathComponent(selectedDir), undo: "Paste")
    }

    // MARK: rename in place

    private func beginRename(_ rel: String, open: Bool = false) {
        guard let n = node(at: rel) else { return }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row)
        guard let tf = (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField else { return }
        tf.isEditable = true; tf.delegate = self
        renaming = (tf, URL(fileURLWithPath: root).appendingPathComponent(rel), open)
        view.window?.makeFirstResponder(tf)
        let name = tf.stringValue as NSString   // the name without its extension, like Finder
        tf.currentEditor()?.selectedRange = NSRange(location: 0, length: n.children == nil ? (name.deletingPathExtension as NSString).length : name.length)
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard let r = renaming, note.object as? NSTextField === r.field else { return }
        renaming = nil; r.field.isEditable = false
        let name = r.field.stringValue.trimmingCharacters(in: .whitespaces)
        var url = r.url
        if !name.isEmpty, !name.contains("/"), name != r.url.lastPathComponent {
            let dst = r.url.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dst.path) { Banner.show(String(localized: "“\(name)” already exists here."), style: .error) }
            else if move([(r.url, dst)], undo: "Rename") { url = dst }
        }
        r.field.stringValue = url.lastPathComponent
        view.window?.makeFirstResponder(outline)
        let rel = String(url.path.dropFirst(root.count + 1))
        reloadTree { [weak self] in
            guard let self, let n = node(at: rel) else { return }
            outline.selectRowIndexes([outline.row(forItem: n)], byExtendingSelection: false)
        }
        if r.open { openFile(rel) }
    }

    /// The node at a relative path, its folders opened.
    private func node(at rel: String) -> FileNode? {
        var list = nodes, found: FileNode?, acc = ""
        for part in rel.split(separator: "/") {
            acc = acc.isEmpty ? String(part) : acc + "/" + part
            guard let f = list.first(where: { $0.path == acc }) else { return nil }
            if f.children != nil, acc != rel { outline.expandItem(f) }
            found = f; list = f.children ?? []
        }
        return found
    }

    // MARK: Quick Look (Space)

    @objc private func togglePreview() {
        guard let p = QLPreviewPanel.shared() else { return }
        if p.isVisible { p.orderOut(nil); return }
        p.makeKeyAndOrderFront(nil)
        if p.dataSource == nil { p.dataSource = self; p.delegate = self; p.reloadData() }   // no key window's chain led here
        if ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] != nil {   // the panel is its own window, not in the PNG
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { print("QUICKLOOK", p.isVisible, p.currentPreviewItem?.previewItemURL?.lastPathComponent ?? "-") }
        }
    }
    private var previewURL: URL? {
        (outline.item(atRow: outline.selectedRow) as? FileNode).map { URL(fileURLWithPath: root).appendingPathComponent($0.path) }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURL as NSURL? }
    /// ↑↓ in the preview walk the tree, like Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [125, 126].contains(event.keyCode) else { return false }
        outline.keyDown(with: event); return true
    }
    func outlineViewSelectionDidChange(_ n: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    private var selectedPath: String? { selectedNode.map { root + "/" + $0.path } }
    private var selectedNode: FileNode? { (outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) : outline.item(atRow: outline.selectedRow)) as? FileNode }
    private var selectedDir: String {
        guard let n = selectedNode else { return "" }
        return n.children != nil ? n.path : (n.path as NSString).deletingLastPathComponent
    }
    @objc private func openSelected() {
        guard let n = selectedNode, NSApp.currentEvent?.type != .rightMouseDown else { return }
        guard n.children == nil else { if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }; return }
        // Like Xcode's navigator: the file opens, the keys stay here (↑↓, Space, ↩, ⌘C).
        openFile(n.path, focus: false)
    }
    /// Like Finder's new folder: "untitled" appears with its name selected; type one and it opens.
    @objc private func newFile() {
        let u = Self.free(URL(fileURLWithPath: root).appendingPathComponent(selectedDir).appendingPathComponent("untitled"), word: nil)
        guard FileManager.default.createFile(atPath: u.path, contents: Data()) else { Banner.show(String(localized: "Couldn't create a file in /\(selectedDir)."), style: .error); return }
        undoManager?.registerUndo(withTarget: self) { $0.trash([u], undo: "New File") }; undoManager?.setActionName("New File")
        let rel = String(u.path.dropFirst(root.count + 1))
        reloadTree { [weak self] in self?.beginRename(rel, open: true) }
    }
    /// Markdown templates from <repo>/.kelp/templates and ~/.kelp/templates with {{date}}, {{branch}}, {{title}}…
    @objc private func newFromTemplate() {
        let repo = AppModel.shared.repo(worktree?.repoId)
        let dirs = [URL(fileURLWithPath: root).appendingPathComponent(".kelp/templates"), Paths.root.appendingPathComponent("templates")]
        let all = dirs.flatMap { Templates.list(in: $0) }
        guard !all.isEmpty else {
            let a = NSAlert(); a.messageText = String(localized: "No templates yet"); a.informativeText = String(localized: "Add Markdown files to .kelp/templates in the repo or ~/.kelp/templates. Placeholders: {{date}}, {{time}}, {{branch}}, {{title}}, {{repo}}.")
            Task { _ = await runSheet(a) }; return
        }
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26)); for t in all { pop.addItem(withTitle: t.deletingPathExtension().lastPathComponent) }
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); name.placeholderString = String(localized: "File name, e.g. plan-login.md")
        let box = NSStackView(views: [pop, name]); box.orientation = .vertical; box.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        let a = NSAlert(); a.messageText = String(localized: "New from Template"); a.accessoryView = box; a.addButton(withTitle: String(localized: "Create")); a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn, !name.stringValue.isEmpty, let text = try? String(contentsOf: all[pop.indexOfSelectedItem], encoding: .utf8) else { return }
            var file = name.stringValue; if (file as NSString).pathExtension.isEmpty { file += ".md" }
            let title = (file as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ")
            let body = Templates.expand(text, vars: ["branch": worktree?.branch ?? "", "title": title, "repo": repo?.name ?? ""])
            let rel = selectedDir.isEmpty ? file : selectedDir + "/" + file
            let u = URL(fileURLWithPath: root).appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try body.write(to: u, atomically: true, encoding: .utf8) } catch { showError(error); return }
            reloadTree(); openFile(rel)
        }
    }

    @objc private func newFolder() {
        guard let name = prompt(String(localized: "New folder"), String(localized: "In /\(selectedDir)")), !name.isEmpty else { return }
        do { try FileManager.default.createDirectory(at: URL(fileURLWithPath: root).appendingPathComponent(selectedDir).appendingPathComponent(name), withIntermediateDirectories: true) }
        catch { showError(error) }
        reloadTree()   // empty folders are invisible to git; it appears once it has a file
    }
    @objc private func rename() {
        guard let n = selectedNode else { NSSound.beep(); return }
        beginRename(n.path)
    }
    @objc private func trashSelected() {
        guard let n = selectedNode else { NSSound.beep(); return }
        trash([URL(fileURLWithPath: root).appendingPathComponent(n.path)], undo: String(localized: "Move to Trash"))
    }
    @objc private func reveal() {
        guard let n = selectedNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root).appendingPathComponent(n.path)])
    }
    @objc private func copyPath() { copyText(selectedPath) }
    @objc private func copyRelativePath() { copyText(selectedNode?.path) }
    private func copyText(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func insertPath() {
        guard let p = selectedPath else { NSSound.beep(); return }
        FileActions.sendToAgent(p)
    }
    @objc private func copyWebLink() {
        guard let p = selectedPath else { NSSound.beep(); return }
        FileActions.copyWebLink(p)
    }
    // MARK: search
    private func showResults(_ on: Bool) { resultsScroll.isHidden = !on; leftScroll.isHidden = on; if !on { noResults?.isHidden = true } }
    /// A search that found nothing says so (and the tree is one click away), rather than an empty list.
    private let noMatches = NSTextField(wrappingLabelWithString: "")
    private var noResults: NSView?
    private var typing: DispatchWorkItem?
    /// Results follow the typing (a pause of a quarter second), like Xcode's Find navigator.
    func controlTextDidChange(_ n: Notification) {
        guard n.object as? NSSearchField === search else { return }
        typing?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.runSearch() }
        typing = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }
    /// ↓ from the field goes into the results; ↩ there opens the line.
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if let r = renaming, c === r.field, sel == #selector(NSResponder.cancelOperation(_:)) {   // Esc keeps the old name
            r.field.stringValue = r.url.lastPathComponent; view.window?.makeFirstResponder(outline); return true
        }
        guard c === search, sel == #selector(NSResponder.moveDown(_:)), !matches.isEmpty, !resultsScroll.isHidden else { return false }
        view.window?.makeFirstResponder(results); results.selectRowIndexes([0], byExtendingSelection: false)
        return true
    }
    @objc func runSearch() {
        guard let w = worktree else { return }
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        showResults(!q.isEmpty)
        guard !q.isEmpty else { return }
        Task {
            matches = (try? await AppModel.shared.client?.call("files.search", .obj(["id": .string(w.id), "query": .string(q)]), as: [SearchMatch].self)) ?? []
            results.reloadData()
            noMatches.stringValue = String(localized: "No matches for “\(q)”."); noResults?.isHidden = !matches.isEmpty
        }
    }
    func numberOfRows(in t: NSTableView) -> Int { matches.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let m = matches[row]
        let top = NSTextField(labelWithString: "\(m.path):\(m.line)"); top.font = .ui(10); top.textColor = .secondaryLabelColor
        let txt = NSTextField(labelWithString: m.text); txt.font = .monospacedSystemFont(ofSize: 11, weight: .regular); txt.lineBreakMode = .byTruncatingTail
        let s = NSStackView(views: [top, txt]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 1
        return s
    }
    @objc private func openResult() {
        let r = results.clickedRow >= 0 ? results.clickedRow : results.selectedRow
        if matches.indices.contains(r) { let m = matches[r]; openFile(m.path, line: m.line) }
    }
}

extension Notification.Name { static let kelpFindInFiles = Notification.Name("kelp.find.files") }

/// Finder's keys in the tree: Space previews, ↩ renames, ⌘⌫ moves to the Trash.
final class FilesOutline: NSOutlineView {
    var onSpace: (() -> Void)?, onReturn: (() -> Void)?, onDelete: (() -> Void)?
    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (e.keyCode, mods) {
        case (49, []): onSpace?()
        case (36, []), (76, []): onReturn?()
        case (51, .command): onDelete?()
        default: super.keyDown(with: e)
        }
    }
}

/// Return in the results opens the line (a click does too).
final class ResultsTable: NSTableView {
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 36 || e.keyCode == 76, let a = action { NSApp.sendAction(a, to: target, from: self); return }
        super.keyDown(with: e)
    }
}
