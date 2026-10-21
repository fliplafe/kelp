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
    private let autosaving = Debounce()
    private var lspTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private let root: String
    private var pendingLine: Int?
    /// Closed with Don't Save: deinit's autosave mustn't write it after all.
    private var discarded = false
    func discard() { discarded = true; isEdited = false }
    /// The file was moved or deleted under the tab (often by an agent): the tab says so, ⌘S asks before writing it back.
    private var gone = false { didSet { if gone != oldValue { onChange?() } } }
    /// A remote project's file: read and written on its host, one save at a time.
    private var isRemote = false
    private var saving: Task<Void, Never>?
    /// Focused while its text was still on the way from the host: focused (and its line shown) once it's here.
    private var focusWhenLoaded = false

    var uri: String { TabURI.file(path) }
    var title: String { url.lastPathComponent }
    var icon: NSImage? { gone ? .symbol("exclamationmark.triangle", String(localized: "Moved or deleted")) : FileIcon.image(url.lastPathComponent) }
    var toolTip: String? { gone ? String(localized: "\(path) was moved or deleted. ⌘S asks before writing it there again.") : path }

    init(uri: String) {
        let (p, line) = TabURI.filePath(uri)
        path = p; url = URL(fileURLWithPath: p); pendingLine = line
        root = AppModel.shared.worktrees.filter { p.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }?.path ?? url.deletingLastPathComponent().path
        let ext = url.pathExtension.lowercased()
        // A remote project's file: read on its host, saved there (an agent's edit there meanwhile is asked about).
        if !FileManager.default.fileExists(atPath: p), let r = RemoteHost.containing(p) {
            isRemote = true
            let box = NSView(); view = box
            let wait = Self.message(String(localized: "Reading it from \(r.remote.host)…")); box.pin(wait)
            Task { [weak self] in
                let res = await AppModel.shared.tryCall("files.readRemote", .obj(["path": .string(p)]))
                guard let self else { return }
                wait.removeFromSuperview()
                guard let text = res.value?.string else { box.pin(Self.message(res.error ?? String(localized: "Couldn't read it."))); return }
                let e = CodeEditor(text: text, url: url, editable: text.utf8.count <= CodeEditor.readOnlyLimit)
                e.view.clipsToBounds = true
                e.onChange = { [weak self] t in self?.edited(t) }
                editor = e; lastSaved = text
                box.pin(e.view)
                if focusWhenLoaded { focus() }
            }
            return
        }
        // Read whole and on the main thread: only a regular file (a pipe or /dev/zero would block or never end), and only
        // up to `openLimit` (a 300 MB log would hang the window). Limit: synchronous read; move it off the main thread
        // if files near the limit feel slow.
        switch Self.unopenable(p) {
        case .special?: view = Self.message(String(localized: "Kelp opens files, not devices or pipes.")); return
        case .tooBig(let n)?:
            let size = ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
            view = Self.message(String(localized: "Too big to open here (\(size)). Open it with another app.")); return
        case nil: break
        }
        if Preview.canPreview(url) { view = Preview.view(for: url); return }
        if ext == "ipynb" {
            let nb = NotebookTab(url: url, path: p, worktreeId: AppModel.shared.worktrees.first { p.hasPrefix($0.path + "/") }?.id)
            notebook = nb; view = nb.view; return
        }
        // Moved or deleted (often by an agent) since the tab was opened: say so, never an empty buffer ⌘S would write.
        guard let data = FileManager.default.contents(atPath: p) else {
            view = Self.message(FileManager.default.fileExists(atPath: p)
                ? String(localized: "Couldn't read this file.") : String(localized: "File not found — it was moved or deleted.")); return
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
            view = stacked(e.view, bar)
        }
        e.onChange = { [weak self] t in self?.edited(t) }
        startLSP()
        // FSEvents reports real paths (/private/tmp…): resolve ours once, not for every path of every event.
        let real = Paths.real(p) ?? p
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
        guard let editor else { focusWhenLoaded = true; return }
        editor.focus()
        if let l = pendingLine { pendingLine = nil; DispatchQueue.main.async { [weak self] in self?.editor?.goTo(line: l) } }
    }
    func goTo(line: Int) { editor?.goTo(line: line); editor?.focus() }
    var selectedText: String? { editor?.selectedText }
    var selectedLines: ClosedRange<Int>? { editor?.selectedLines }
    /// Asks about unsaved changes in a sheet, like any Mac document: Save, Don't Save, or keep the tab. With autosave
    /// it only asks when writing isn't safe: an agent changed the file meanwhile, or it was moved or deleted.
    func close() -> Bool {
        autosaving.cancel()
        guard let e = editor, isEdited else { return true }
        let action = isRemote ? .write : FileSync.save(buffer: e.text, saved: lastSaved, disk: disk)
        if Self.autosave, action == .write, writeAndClose() { return true }
        let a = NSAlert(); a.messageText = String(localized: "Do you want to save the changes you made to “\(title)”?")
        a.informativeText = switch action {
        case .conflict: String(localized: "An agent changed it on disk meanwhile. Save replaces that version with yours.")
        case .missing: String(localized: "It was moved or deleted. Save writes it at its old place again.")
        default: String(localized: "Your changes will be lost if you don't save them.")
        }
        a.addButton(withTitle: String(localized: "Save")); a.addButton(withTitle: String(localized: "Cancel")); a.addButton(withTitle: String(localized: "Don't Save"))
        switch runAsSheet(a) {
        case .alertFirstButtonReturn: return writeAndClose()
        case .alertThirdButtonReturn: discarded = true; return true
        default: return false
        }
    }

    // MARK: saving

    private func edited(_ t: String) {
        if Self.autosave { autosaving.after(0.6) { [weak self] in self?.autosaveNow() } }
        editedStateMayHaveChanged()
        markdown?.textChanged()
        guard !isRemote else { return }   // no language server for a file on another machine
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
        if isRemote { return write() }
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
        if isRemote { write(); return }
        switch FileSync.save(buffer: e.text, saved: lastSaved, disk: disk) {
        case .write: write()
        case .conflict: diskChanged()
        default: break
        }
    }

    @discardableResult
    private func write() -> Bool {
        guard let e = editor else { return true }
        if isRemote { writeRemote(); return true }
        // Through a symlink to the file it points at: an atomic write to the link would replace it with a plain file.
        do { try e.text.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8); lastSaved = e.text; gone = false }
        catch { Banner.show(String(localized: "Couldn't save \(title): \(error.localizedDescription)"), style: .error); return false }
        editedStateMayHaveChanged()
        return true
    }

    /// Closing with a save: a remote file's tab stays until the host has it (a failed save keeps the edits), then closes.
    private func writeAndClose() -> Bool {
        guard isRemote else { return write() }
        writeRemote { [uri] in Workbench.closeTab(uri: uri) }
        return false
    }

    var pendingSave: Task<Void, Never>? { saving }

    /// Each save waits for the one before, so it's checked against what that one wrote, not what's in flight.
    /// It holds the tab: one closed (or its workspace) right after Save still gets written.
    private func writeRemote(then done: (() -> Void)? = nil) {
        let previous = saving
        saving = Task { [self] in
            await previous?.value
            guard let e = editor, e.text != lastSaved else { done?(); return }
            let text = e.text
            let res = await AppModel.shared.tryCall("files.writeRemote", .obj(["path": .string(path), "text": .string(text), "base": .string(lastSaved)]))
            if let error = res.error { Banner.show(String(localized: "Couldn't save \(title): \(error)"), style: .error); return }
            if let now = res.value?["changed"]?.string { askKeepMine(disk: now); return }
            lastSaved = text; editedStateMayHaveChanged(); done?()
        }
    }

    private func editedStateMayHaveChanged() {
        let now = editor.map { $0.text != lastSaved } ?? false
        guard now != isEdited else { return }
        isEdited = now; onChange?()
    }

    private func diskChanged() {
        // Grown past the limit (a log) or replaced by a pipe: keep what's shown rather than read it all again.
        guard let e = editor, Self.unopenable(path) == nil else { return }
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
        let vars = ["file": path, "relativeFile": relative, "dir": url.deletingLastPathComponent().path, "line": String(line), "symbol": symbol, "workspace": root]
        return ShellTemplate.fill(template) { vars[$0] }
    }

    /// Format Document: the text goes to the language's `format` on stdin and comes back formatted, as one undoable
    /// edit with the cursor on its line. A failure shows the command's first lines of error.
    func format() async {
        guard FileManager.default.isWritableFile(atPath: path) else { NSSound.beep(); return }   // a remote or read-only file
        guard let cmd = await command("format"), let e = editor else { return }
        guard LSPManager.shared.askTrust(root, { [weak self] in Task { await self?.format() } }) else { return }   // its toolchain may be the repo's
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

    /// Bigger than this isn't opened (read only from 5 MB, `CodeEditor.readOnlyLimit`).
    static let openLimit = 50 << 20
    enum Unopenable: Equatable { case special, tooBig(Int) }
    /// Why `p` (followed through symlinks) isn't opened; nil when it is, or when it's missing (said elsewhere).
    static func unopenable(_ p: String) -> Unopenable? {
        var st = stat()
        guard stat(p, &st) == 0 else { return nil }
        if st.st_mode & S_IFMT != S_IFREG { return .special }
        return st.st_size > openLimit ? .tooBig(Int(st.st_size)) : nil
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
