import AppKit
import Core
import EditorKit
import GitKit
import WorkbenchKit

/// A file as a tab: code editor with LSP, Markdown with preview, notebooks, or a Quick Look preview.
/// Like a Mac document: edits show as a dot on the tab and the window's close button, ⌘S saves, closing asks
/// (Settings › Editor › Save automatically turns autosave on). Agents edit files on disk too: unchanged buffers
/// follow the disk; conflicting edits ask.
@MainActor
final class FileTab: SavableTab {
    let path: String, url: URL
    var onChange: (() -> Void)?
    let view: NSView
    private(set) var editor: CodeEditor?
    private(set) var markdown: MarkdownTab?
    private var notebook: NotebookTab?
    private var lastSaved = ""
    private(set) var isEdited = false
    private static var autosave: Bool { SettingsStore.shared.bool("editor.autoSave") == true }
    private var saveTask: Task<Void, Never>?
    private var lspTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private let root: String
    private var pendingLine: Int?
    /// Closed with Don't Save: deinit's autosave mustn't write it after all.
    private var discarded = false
    /// The file was moved or deleted under the tab (often by an agent): the tab says so, ⌘S asks before writing it back.
    private var gone = false { didSet { if gone != oldValue { onChange?() } } }

    var uri: String { TabURI.file(path) }
    var title: String { url.lastPathComponent }
    var icon: NSImage? { gone ? .symbol("exclamationmark.triangle", String(localized: "Moved or deleted")) : FileIcon.image(url.lastPathComponent) }
    var toolTip: String? { gone ? String(localized: "\(path) was moved or deleted. ⌘S asks before writing it there again.") : path }

    init(uri: String) {
        let (p, line) = TabURI.filePath(uri)
        path = p; url = URL(fileURLWithPath: p); pendingLine = line
        root = AppModel.shared.worktrees.filter { p.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }?.path ?? url.deletingLastPathComponent().path
        let ext = url.pathExtension.lowercased()
        // A remote project's file: read on its host and shown read-only (edits happen there, by its agents and terminals).
        if !FileManager.default.fileExists(atPath: p), let r = RemoteHost.containing(p) {
            let box = NSView(); view = box
            let wait = Self.message(String(localized: "Reading it from \(r.remote.host)…")); Self.pin(wait, in: box)
            Task { [weak self] in
                let res = await AppModel.shared.tryCall("files.readRemote", .obj(["path": .string(p)]))
                guard let self else { return }
                wait.removeFromSuperview()
                guard let text = res.value?.string else { Self.pin(Self.message(res.error ?? String(localized: "Couldn't read it.")), in: box); return }
                let e = CodeEditor(text: text, url: url, editable: false)
                e.view.clipsToBounds = true
                editor = e; lastSaved = text
                Self.pin(e.view, in: box)
            }
            return
        }
        if Preview.canPreview(url) { view = Preview.view(for: url); return }
        if ext == "ipynb" {
            let nb = NotebookTab(url: url, path: p, worktreeId: AppModel.shared.worktrees.first { p.hasPrefix($0.path + "/") }?.id)
            nb.currentSession = { Workbench.shared.focusedSession }
            notebook = nb; view = nb.view; return
        }
        // Moved or deleted (often by an agent) since the tab was opened: say so, never an empty buffer ⌘S would write.
        guard let data = FileManager.default.contents(atPath: p) else {
            view = Self.message(FileManager.default.fileExists(atPath: p) ? String(localized: "Couldn't read this file.") : String(localized: "File not found — it was moved or deleted.")); return
        }
        guard let text = String(data: data, encoding: .utf8) else { view = Self.message(String(localized: "Binary file — open it with another app.")); return }
        let e = CodeEditor(text: text, url: url, editable: data.count <= CodeEditor.readOnlyLimit)
        e.view.clipsToBounds = true
        editor = e; lastSaved = text
        if ["md", "markdown"].contains(ext) {
            let md = MarkdownTab(editor: e, url: url)
            md.startInPreview = p == Help.location.path   // the help is for reading
            markdown = md; view = md.view
        } else {
            let bar = EditorStatusBar(url: url, text: text)
            bar.show(cursor: e.cursor)
            e.onSelection = { [weak bar, weak e] in bar?.show(cursor: e?.cursor) }
            view = EditorStatusBar.wrap(e.view, bar: bar)
        }
        e.onChange = { [weak self] t in self?.edited(t) }
        startLSP()
        // FSEvents reports real paths (/private/tmp…): resolve ours once, not for every path of every event.
        let real = FileWatcher.real(p)
        watcher = FileWatcher(root: url.deletingLastPathComponent().path) { [weak self] paths in
            guard paths.contains(where: { $0 == real || $0 == p }) else { return }
            self?.diskChanged()
        }
        track(owner: self) { ThemeManager.shared.editorRevision } changed: { [weak self] _ in self?.editor?.refreshAppearance() }
    }
    isolated deinit {
        // Dropped without close() (its workspace went away): autosave writes what's safe to write, never over a conflict.
        if Self.autosave, !discarded, let e = editor, FileSync.save(buffer: e.text, saved: lastSaved, disk: disk) == .write { write() }
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
    /// Asks about unsaved changes in a sheet, like any Mac document: Save, Don't Save, or keep the tab. With autosave
    /// it only asks when writing isn't safe: an agent changed the file meanwhile, or it was moved or deleted.
    func close() -> Bool {
        saveTask?.cancel()
        guard let e = editor, isEdited else { return true }
        let action = FileSync.save(buffer: e.text, saved: lastSaved, disk: disk)
        if Self.autosave, action == .write, write() { return true }
        let a = NSAlert(); a.messageText = String(localized: "Do you want to save the changes you made to “\(title)”?")
        a.informativeText = switch action {
        case .conflict: String(localized: "An agent changed it on disk meanwhile. Save replaces that version with yours.")
        case .missing: String(localized: "It was moved or deleted. Save writes it at its old place again.")
        default: String(localized: "Your changes will be lost if you don't save them.")
        }
        a.addButton(withTitle: String(localized: "Save")); a.addButton(withTitle: String(localized: "Cancel")); a.addButton(withTitle: String(localized: "Don't Save"))
        switch runAsSheet(a) {
        case .alertFirstButtonReturn: return write()
        case .alertThirdButtonReturn: discarded = true; return true
        default: return false
        }
    }

    // MARK: saving

    private func edited(_ t: String) {
        if Self.autosave {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { self?.autosaveNow() }
            }
        }
        editedStateMayHaveChanged()
        markdown?.textChanged()
        lspTask?.cancel()
        let p = path, r = root
        lspTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let c = await LSPManager.shared.client(root: r, path: p) else { return }
            c.change(p, text: t)
        }
    }

    private var disk: FileSync.Disk {
        FileManager.default.fileExists(atPath: path) ? .present(try? String(contentsOf: url, encoding: .utf8)) : .missing
    }

    /// ⌘S. False when it couldn't be written, or the user is asked first (an agent changed the file meanwhile, or it's gone).
    @discardableResult
    func save() -> Bool {
        guard let e = editor else { return true }
        switch FileSync.save(buffer: e.text, saved: lastSaved, disk: disk) {
        case .write: return write()
        case .conflict: diskChanged(); return false   // don't clobber an agent's edit
        case .missing:   // moved or deleted (git mv, a rename): writing would bring the old file back beside the new one
            let a = NSAlert(); a.messageText = String(localized: "“\(title)” was moved or deleted")
            a.informativeText = String(localized: "Save writes it at its old place again.")
            a.addButton(withTitle: String(localized: "Save Here")); a.addButton(withTitle: String(localized: "Cancel"))
            return runAsSheet(a) == .alertFirstButtonReturn && write()
        default: return true
        }
    }

    /// Autosave writes only when that's safe; a conflict asks (if the tab is on screen), a missing file waits for ⌘S.
    private func autosaveNow() {
        guard let e = editor else { return }
        switch FileSync.save(buffer: e.text, saved: lastSaved, disk: disk) {
        case .write: write()
        case .conflict: diskChanged()
        default: break
        }
    }

    @discardableResult
    private func write() -> Bool {
        guard let e = editor else { return true }
        // Through a symlink to the file it points at: an atomic write to the link would replace it with a plain file.
        do { try e.text.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8); lastSaved = e.text; gone = false }
        catch { Banner.show(String(localized: "Couldn't save \(title): \(error.localizedDescription)"), style: .error); return false }
        editedStateMayHaveChanged()
        return true
    }

    private func editedStateMayHaveChanged() {
        let now = editor.map { $0.text != lastSaved } ?? false
        guard now != isEdited else { return }
        isEdited = now; onChange?()
    }

    private func diskChanged() {
        guard let e = editor else { return }
        let d = disk
        let wasGone = gone
        gone = d == .missing
        switch FileSync.diskChanged(buffer: e.text, saved: lastSaved, disk: d) {
        case .follow(let text): e.setText(text); lastSaved = text; markdown?.textChanged(); editedStateMayHaveChanged()   // no local edits: follow the disk
        case .conflict(let text): askKeepMine(disk: text)
        case .missing where !wasGone && isEdited:
            Banner.show(String(localized: "\(title) was moved or deleted. ⌘S asks before writing it there again."))
        default: break
        }
    }

    private func askKeepMine(disk: String) {
        guard let e = editor, let w = view.window, w.attachedSheet == nil else { return }   // asked again on the next change or ⌘S
        let a = NSAlert(); a.messageText = String(localized: "\(title) changed on disk")
        a.informativeText = String(localized: "An agent edited this file while you had unsaved changes.")
        // No longer text (another encoding, binary): there's no disk version to show, and an empty one would throw the
        // edits away. Keep Mine writes them; Cancel leaves the tab and the file as they are.
        let notText: Bool = if case .present(nil) = self.disk { true } else { false }
        if notText { a.informativeText = String(localized: "The file on disk is no longer text (another encoding, or binary). Keep Mine writes your version over it.") }
        a.addButton(withTitle: String(localized: "Keep Mine")); a.addButton(withTitle: notText ? String(localized: "Cancel") : String(localized: "Use Disk Version"))
        // Holds the tab until answered: closing it meanwhile mustn't throw away the user's choice (or their edits).
        a.beginSheetModal(for: w) { r in
            MainActor.assumeIsolated {
                if r == .alertFirstButtonReturn { self.lastSaved = disk; self.write() }
                else if !notText { e.setText(disk); self.lastSaved = disk; self.markdown?.textChanged() }
                self.editedStateMayHaveChanged()
            }
        }
    }

    private func startLSP() {
        let p = path, r = root
        guard LSPManager.shared.language(p)?.server != nil,
              LSPManager.shared.whenTrusted(r, { [weak self] in self?.startLSP() }) else { return }   // asked once per project
        Task { [weak self] in
            guard let c = await LSPManager.shared.client(root: r, path: p), let e = self?.editor, let lang = LSPManager.shared.language(p) else { return }
            c.open(p, text: e.text, languageId: lang.id)
            e.completionProvider = { line, col in   // the current client: a server that died is replaced
                guard let c = await LSPManager.shared.client(root: r, path: p) else { return [] }
                return ((try? await c.completion(p, line: line, column: col)) ?? []).map { CodeEditor.Completion(label: $0.label, detail: $0.detail, insert: $0.insert) }
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

    // MARK: language commands

    var language: LanguageSpec? { LSPManager.shared.language(path) }

    /// The language's `run`, `test` or `format` with this file's variables filled in. Nil when there's none (a beep
    /// for a file of no language, else a banner).
    func command(_ name: String) async -> String? {
        guard let lang = language, editor != nil else { NSSound.beep(); return nil }
        guard let template = lang[command: name] else { Banner.show(String(localized: "\(lang.id) has no “\(name)” command.")); return nil }
        let (line, column) = editor?.cursor ?? (1, 1)
        var symbol = ""
        if template.contains("${symbol}") {
            let client = await LSPManager.shared.client(root: root, path: path)
            symbol = (try? await client?.symbol(path, line: line)) ?? LanguageSpec.word(in: editor?.text ?? "", line: line, column: column)
        }
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        return LanguageSpec.expand(template, ["file": path, "relativeFile": relative, "dir": url.deletingLastPathComponent().path,
                                              "line": String(line), "symbol": symbol, "workspace": root])
    }

    /// Format Document: the text goes to the language's `format` on stdin and comes back formatted, as one undoable
    /// edit with the cursor on its line. A failure shows the command's first lines of error.
    func format() async {
        guard FileManager.default.isWritableFile(atPath: path) else { NSSound.beep(); return }   // a remote or read-only file
        guard let cmd = await command("format"), let e = editor else { return }
        let text = e.text, line = e.cursor?.line ?? 1
        let r = await Shell.run(cmd, cwd: url.deletingLastPathComponent().path, input: text, timeout: 20)
        guard r.code == 0 else {
            let why = (r.stderr.isEmpty ? r.stdout : r.stderr).split(separator: "\n").prefix(2).joined(separator: "\n")
            Banner.show(String(localized: "Couldn't format \(title): \(why)"), style: .error); return
        }
        guard e.text == text, r.stdout != text, !r.stdout.isEmpty || text.isEmpty else { return }   // typed meanwhile, or nothing to do
        e.apply(text: r.stdout, selection: NSRange(location: 0, length: 0))
        e.goTo(line: line)
    }

    private static func pin(_ v: NSView, in box: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: box.topAnchor), v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: box.leadingAnchor), v.trailingAnchor.constraint(equalTo: box.trailingAnchor)])
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
