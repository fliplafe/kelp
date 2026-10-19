import AppKit
import Core
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
final class FilesPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let outline = NSOutlineView()
    private let results = NSTableView()
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
        // Grouped like Finder's: open, create, change, locate, hand to the agent.
        let m = NSMenu()
        for group in [[("Open", #selector(openSelected))],
                      [("New File…", #selector(newFile)), ("New Folder…", #selector(newFolder)), ("New from Template…", #selector(newFromTemplate))],
                      [("Rename…", #selector(rename)), ("Move to Trash", #selector(trash))],
                      [("Reveal in Finder", #selector(reveal)), ("Copy Path", #selector(copyPath)), ("Copy Relative Path", #selector(copyRelativePath))],
                      [("Insert Path into Agent Prompt", #selector(insertPath))]] {
            if !m.items.isEmpty { m.addItem(.separator()) }
            for (t, a) in group { m.addItem(withTitle: t, action: a, keyEquivalent: "").target = self }
        }
        let openIn = NSMenu()
        WorkspaceActions.addOpenIn(to: openIn, path: { [weak self] in self?.selectedPath }, prefix: "")
        if !openIn.items.isEmpty, let i = m.items.firstIndex(where: { $0.action == #selector(reveal) }) {
            m.insertItem(withTitle: "Open In", action: nil, keyEquivalent: "", at: i + 1).submenu = openIn
        }
        outline.menu = m
        leftScroll.documentView = outline; leftScroll.hasVerticalScroller = true; leftScroll.drawsBackground = false
        let rc = NSTableColumn(identifier: .init("r")); results.addTableColumn(rc); results.headerView = nil; results.style = .sourceList
        results.dataSource = self; results.delegate = self; results.rowHeight = 34; results.target = self; results.action = #selector(openResult)
        resultsScroll.documentView = results; resultsScroll.hasVerticalScroller = true; resultsScroll.isHidden = true; resultsScroll.drawsBackground = false
        // One field, like Finder's: empty shows the tree, a search (↩) shows matches in their place, clearing it goes back.
        search.placeholderString = "Search in Files"; search.target = self; search.action = #selector(runSearch); search.sendsSearchStringImmediately = false
        search.controlSize = .small
        let v = NSView()
        for x in [search, leftScroll, resultsScroll] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
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
    }

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

    func reloadTree() {
        guard let w = worktree else { nodes = []; outline.reloadData(); return }
        Task {
            let paths = (try? await AppModel.shared.client?.call("files.list", .obj(["id": .string(w.id)]), as: [String].self)) ?? []
            let st = (try? await AppModel.shared.client?.call("git.status", .obj(["id": .string(w.id)]), as: [FileChange].self)) ?? []
            let expanded = Set((0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode).flatMap { outline.isItemExpanded($0) ? $0.path : nil } })
            status = Dictionary(st.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            nodes = FileNode.tree(paths); outline.reloadData()
            func expand(_ ns: [FileNode]) { for n in ns where n.children != nil && expanded.contains(n.path) { outline.expandItem(n); expand(n.children ?? []) } }
            expand(nodes)
        }
    }

    private func openFile(_ rel: String, line: Int? = nil) { Workbench.open(TabURI.file(root + "/" + rel, line: line)) }
    private func showError(_ e: Error) { Banner.show(e.localizedDescription) }
    private var currentSession: () -> String? { { Workbench.shared.focusedSession } }

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
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
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
            catch { showError(error); return false }
        }
        reloadTree(); return true
    }

    private var selectedPath: String? { selectedNode.map { root + "/" + $0.path } }
    private var selectedNode: FileNode? { (outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) : outline.item(atRow: outline.selectedRow)) as? FileNode }
    private var selectedDir: String {
        guard let n = selectedNode else { return "" }
        return n.children != nil ? n.path : (n.path as NSString).deletingLastPathComponent
    }
    @objc private func openSelected() {
        guard let n = selectedNode, NSApp.currentEvent?.type != .rightMouseDown else { return }
        if n.children == nil { openFile(n.path) } else if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
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
            do { try body.write(to: u, atomically: true, encoding: .utf8) } catch { showError(error); return }
            reloadTree(); openFile(rel)
        }
    }

    @objc private func newFolder() {
        guard let name = prompt("New folder", "In /\(selectedDir)"), !name.isEmpty else { return }
        do { try FileManager.default.createDirectory(at: URL(fileURLWithPath: root).appendingPathComponent(selectedDir).appendingPathComponent(name), withIntermediateDirectories: true) }
        catch { showError(error) }
        reloadTree()   // empty folders are invisible to git; it appears once it has a file
    }
    @objc private func rename() {
        guard let n = selectedNode, let name = prompt("Rename", n.path, initial: n.name), !name.isEmpty, name != n.name else { return }
        let src = URL(fileURLWithPath: root).appendingPathComponent(n.path)
        do { try FileManager.default.moveItem(at: src, to: src.deletingLastPathComponent().appendingPathComponent(name)) } catch { showError(error) }
        reloadTree()
    }
    @objc private func trash() {
        guard let n = selectedNode else { return }
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: root).appendingPathComponent(n.path), resultingItemURL: nil) } catch { showError(error) }
        reloadTree()
    }
    @objc private func reveal() {
        guard let n = selectedNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root).appendingPathComponent(n.path)])
    }
    @objc private func copyPath() { copy(selectedPath) }
    @objc private func copyRelativePath() { copy(selectedNode?.path) }
    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func insertPath() {
        guard let n = selectedNode, let sid = currentSession() else { NSSound.beep(); return }
        Task { await AppModel.shared.call("session.send", .obj(["id": .string(sid), "text": .string(n.path + " "), "enter": false])) }
    }
    // MARK: search
    private func showResults(_ on: Bool) { resultsScroll.isHidden = !on; leftScroll.isHidden = on }
    @objc func runSearch() {
        guard let w = worktree else { return }
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        showResults(!q.isEmpty)
        guard !q.isEmpty else { return }
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
