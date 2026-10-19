import AppKit
import Core
import GitKit
import EditorKit

/// A file as a tab: code editor with LSP, Markdown with preview, notebooks, or a Quick Look preview.
/// Like a Mac document: edits show as a dot on the tab and the window's close button, ⌘S saves, closing asks
/// (Settings › Editor › Save automatically turns autosave on). Agents edit files on disk too: unchanged buffers
/// follow the disk; conflicting edits ask.
@MainActor
final class FileTab: TabContent {
    let path: String, url: URL
    var onChange: (() -> Void)?
    let view: NSView
    private var editor: CodeEditor?
    private var markdown: MarkdownTab?
    private var notebook: NotebookTab?
    private var lastSaved = ""
    private var wasEdited = false
    var isEdited: Bool { editor.map { $0.text != lastSaved } ?? false }
    private static var autosave: Bool { SettingsStore.shared.bool("editor.autoSave") == true }
    private var saveTask: Task<Void, Never>?
    private var lspTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var observer: NSObjectProtocol?
    private let root: String
    private var pendingLine: Int?

    var uri: String { TabURI.file(path) }
    var title: String { url.lastPathComponent }
    var icon: NSImage? { NSWorkspace.shared.icon(forFile: path).resized(16) }
    var toolTip: String? { path }

    init(uri: String) {
        let (p, line) = TabURI.filePath(uri)
        path = p; url = URL(fileURLWithPath: p); pendingLine = line
        root = AppModel.shared.worktrees.filter { p.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }?.path ?? url.deletingLastPathComponent().path
        let ext = url.pathExtension.lowercased()
        if Preview.canPreview(url) { view = Preview.view(for: url); return }
        if ext == "ipynb" {
            let nb = NotebookTab(url: url, path: p, worktreeId: AppModel.shared.worktrees.first { p.hasPrefix($0.path + "/") }?.id)
            nb.currentSession = { Workbench.shared.focusedSession }
            notebook = nb; view = nb.view; return
        }
        let data = FileManager.default.contents(atPath: p) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { view = Self.message("Binary file — open it with another app."); return }
        let e = CodeEditor(text: text, url: url, editable: data.count <= CodeEditor.readOnlyLimit)
        e.view.clipsToBounds = true
        editor = e; lastSaved = text
        if ["md", "markdown"].contains(ext) {
            let md = MarkdownTab(editor: e, url: url, path: p); md.currentSession = { Workbench.shared.focusedSession }
            markdown = md; view = md.view
        } else { view = e.view }
        e.onChange = { [weak self] t in self?.edited(t) }
        startLSP()
        watcher = FileWatcher(root: url.deletingLastPathComponent().path) { [weak self] paths in
            guard let self, paths.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == self.url.resolvingSymlinksInPath() }) else { return }
            self.diskChanged()
        }
        observer = NotificationCenter.default.addObserver(forName: .krillAppearance, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.editor?.refreshAppearance() }
        }
    }
    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if Self.autosave { flush() }
        let path = path, root = root
        Task { await LSPManager.shared.client(root: root, path: path)?.close(path) }
    }

    func focus() {
        editor?.focus()
        if let l = pendingLine { pendingLine = nil; DispatchQueue.main.async { [weak self] in self?.editor?.goTo(line: l) } }
    }
    func goTo(line: Int) { editor?.goTo(line: line); editor?.focus() }
    var selectedText: String? { editor?.selectedText }
    var selectedLines: ClosedRange<Int>? { editor?.selectedLines }
    /// Asks about unsaved changes in a sheet, like any Mac document: Save, Don't Save, or keep the tab.
    func close() -> Bool {
        if Self.autosave { flush(); return true }
        guard isEdited else { return true }
        let a = NSAlert(); a.messageText = "Do you want to save the changes you made to “\(title)”?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Don't Save")
        switch runAsSheet(a) {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: saving

    private func edited(_ t: String) {
        if Self.autosave {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { self?.save() }
            }
        }
        editedStateMayHaveChanged()
        markdown?.textChanged()
        if let wid = AppModel.shared.worktrees.first(where: { $0.path == root })?.id, let line = editor?.cursor?.line {
            Attribution.markHuman(worktree: wid, file: String(path.dropFirst(root.count + 1)), line: line)
        }
        lspTask?.cancel()
        let p = path, r = root
        lspTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let c = await LSPManager.shared.client(root: r, path: p) else { return }
            c.change(p, text: t)
        }
    }

    /// ⌘S. False when it couldn't be written (or an agent changed the file meanwhile and the user is asked).
    @discardableResult
    func save() -> Bool {
        guard let e = editor, e.text != lastSaved else { return true }
        if let disk = try? String(contentsOf: url, encoding: .utf8), disk != lastSaved { diskChanged(); return false }   // don't clobber an agent's edit
        do { try e.text.write(to: url, atomically: true, encoding: .utf8); lastSaved = e.text }
        catch { Banner.show("Couldn't save \(title): \(error.localizedDescription)"); return false }
        editedStateMayHaveChanged()
        return true
    }
    private func flush() { saveTask?.cancel(); save() }

    private func editedStateMayHaveChanged() {
        guard isEdited != wasEdited else { return }
        wasEdited = isEdited; onChange?()
    }

    private func diskChanged() {
        guard let e = editor, let disk = try? String(contentsOf: url, encoding: .utf8), disk != lastSaved else { return }
        if e.text == lastSaved { e.setText(disk); lastSaved = disk; markdown?.textChanged(); editedStateMayHaveChanged(); return }   // no local edits: follow the disk
        let a = NSAlert(); a.messageText = "\(title) changed on disk"
        a.informativeText = "An agent edited this file while you had unsaved changes."
        a.addButton(withTitle: "Keep Mine"); a.addButton(withTitle: "Use Disk Version")
        guard let w = view.window else { return }
        a.beginSheetModal(for: w) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self else { return }
                if r == .alertFirstButtonReturn { self.lastSaved = disk; self.save() } else { e.setText(disk); self.lastSaved = disk }
                self.editedStateMayHaveChanged()
            }
        }
    }

    private func startLSP() {
        guard SettingsStore.shared.bool("editor.lsp") != false else { return }
        let p = path, r = root
        Task { [weak self] in
            guard let c = await LSPManager.shared.client(root: r, path: p), let e = self?.editor else { return }
            c.open(p, text: e.text)
            e.completionProvider = { line, col in
                ((try? await c.completion(p, line: line, column: col)) ?? []).map { CodeEditor.Completion(label: $0.label, detail: $0.detail, insert: $0.insert) }
            }
        }
    }

    /// LSP: definition of the symbol at the cursor, opened as a tab.
    func jumpToDefinition() {
        guard let e = editor, let (l, c) = e.cursor else { return }
        let p = path, r = root
        Task {
            guard let client = await LSPManager.shared.client(root: r, path: p), let loc = try? await client.definition(p, line: l, column: c) else { NSSound.beep(); return }
            Workbench.open(TabURI.file(loc.path, line: loc.line))
        }
    }

    private static func message(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s); l.textColor = .secondaryLabelColor
        let v = NSView(); l.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(l)
        NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: v.centerXAnchor), l.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        return v
    }
}

extension NSImage {
    func resized(_ side: CGFloat) -> NSImage {
        let img = copy() as? NSImage ?? self
        img.size = NSSize(width: side, height: side)
        return img
    }
}
