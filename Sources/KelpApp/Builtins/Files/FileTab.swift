import AppKit
import Core
import EditorKit
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
    /// The connection (`AppModel.connections`) its language server was given this file on; nil when it has none. A new
    /// daemon knows nothing of it: the file is given again.
    private var lspOpenedOn: Int?
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
    var fileURL: URL? { url }
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
                let read: Result<String, Error>
                do { read = .success(try await AppModel.shared.get(FilesReadRemote(path: p))) } catch { read = .failure(error) }
                guard let self else { return }
                wait.removeFromSuperview()
                // The host refuses what a tab here refuses (a pipe, too big, not UTF-8), and says it the same way.
                guard case .success(let text) = read else {
                    if case .failure(let e) = read { box.pin(Self.message(Unopenable(e).map(Self.reason) ?? AppModel.message(e))) }
                    return
                }
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
        // up to `openLimit` (a 300 MB log would hang the window). Limit: synchronous first read; move it off the main
        // thread if files near the limit feel slow.
        if let u = Self.unopenable(p) { view = Self.message(Self.reason(u)); return }
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
        guard let text = String(data: data, encoding: .utf8) else { view = Self.message(Self.reason(.binary)); return }
        let e = CodeEditor(text: text, url: url, editable: data.count <= CodeEditor.readOnlyLimit)
        e.view.clipsToBounds = true
        editor = e; lastSaved = text; known = Stamp(p).map { ($0, text) }
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
        track(owner: self) { AppModel.shared.connections } changed: { [weak self] now in
            guard let self, let was = lspOpenedOn, was != now else { return }
            lspOpenedOn = nil; startLSP()
        }
        // FSEvents reports real paths (/private/tmp…): resolve ours once, not for every path of every event.
        let real = Paths.real(p) ?? p
        watcher = FileWatcher(root: url.deletingLastPathComponent().path) { [weak self] paths in
            guard paths.contains(where: { $0 == real || $0 == p }) else { return }
            MainActor.assumeIsolated { self?.diskChanged() }   // delivered on main
        }
        track(owner: self) { ThemeManager.shared.editorRevision } changed: { [weak self] _ in self?.editor?.refreshAppearance() }
    }
    isolated deinit {
        // Dropped without close() (its workspace went away): autosave writes what's safe to write, never over a conflict.
        if Self.autosave, !discarded, let e = editor, FileSync.save(buffer: e.text, saved: lastSaved, disk: disk) == .write { write() }
        if lspOpenedOn != nil { LSPManager.shared.close(root: root, path: path) }
    }

    func focus() {
        guard let editor else {
            // A preview (an image, a PDF) takes the keys itself, so ⌘C copies from it.
            if view.acceptsFirstResponder { view.window?.makeFirstResponder(view) } else { focusWhenLoaded = true }
            return
        }
        editor.focus()
        if let l = pendingLine { pendingLine = nil; DispatchQueue.main.async { [weak self] in self?.editor?.goTo(line: l) } }
    }
    func goTo(line: Int) { editor?.goTo(line: line); editor?.focus() }
    var selectedText: String? { editor?.selectedText }
    var selectedLines: ClosedRange<Int>? { editor?.selectedLines }
    /// Asks about unsaved changes in a sheet, like any Mac document: Save, Don't Save, or keep the tab. With autosave
    /// it only asks when writing isn't safe: an agent changed the file meanwhile, or it was moved or deleted.
    func close() async -> Bool {
        autosaving.cancel()
        guard let e = editor, isEdited else { return true }
        let action = isRemote ? .write : FileSync.save(buffer: e.text, saved: lastSaved, disk: disk)
        if Self.autosave, action == .write, await writeAndClose() { return true }
        let a = NSAlert(); a.messageText = String(localized: "Do you want to save the changes you made to “\(title)”?")
        a.informativeText = switch action {
        case .conflict: String(localized: "An agent changed it on disk meanwhile. Save replaces that version with yours.")
        case .missing: String(localized: "It was moved or deleted. Save writes it at its old place again.")
        default: String(localized: "Your changes will be lost if you don't save them.")
        }
        a.addButton(withTitle: String(localized: "Save")); a.addButton(withTitle: String(localized: "Cancel")); a.addButton(withTitle: String(localized: "Don't Save"))
        switch await runSheet(a) {
        case .alertFirstButtonReturn: return await writeAndClose()
        case .alertThirdButtonReturn: discarded = true; return true
        default: return false
        }
    }

    // MARK: saving

    private func edited(_ t: String) {
        if Self.autosave { autosaving.after(0.6) { [weak self] in self?.autosaveNow() } }
        editedStateMayHaveChanged()
        markdown?.textChanged()
        guard !isRemote, lspOpenedOn != nil else { return }   // no language server for it (or for a file on another machine)
        lspTask?.cancel()
        let p = path, r = root
        lspTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            LSPManager.shared.change(root: r, path: p, text: t)
        }
    }

    /// The file on disk now. Read again only when its stamp changed since the last read or write here: a save's check and
    /// every file event would otherwise read the whole file, on the main thread.
    private var disk: FileSync.Disk {
        guard let now = Stamp(path) else { return .missing }
        if let known, known.stamp == now { return .present(known.text) }
        let text = try? String(contentsOf: url, encoding: .utf8)
        known = (now, text)
        return .present(text)
    }
    /// What was last read from disk or written there, and its stamp.
    private var known: (stamp: Stamp, text: String?)?
    /// A file's size, modification time and inode, through symlinks: the same stamp, the same text.
    private struct Stamp: Equatable {
        let size: Int64, modified: Double, inode: UInt64
        init?(_ p: String) {
            var st = stat()
            guard stat(p, &st) == 0 else { return nil }
            size = st.st_size; inode = UInt64(st.st_ino)
            modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        }
    }
    private var reading = false, readAgain = false

    /// ⌘S. False when it couldn't be written, or the user is asked first (an agent changed the file meanwhile, or it's gone).
    @discardableResult
    func save() async -> Bool {
        guard let e = editor else { return true }
        if isRemote { return write() }
        switch FileSync.save(buffer: e.text, saved: lastSaved, disk: disk) {
        case .write: return write()
        case .conflict: apply(disk); return false   // don't clobber an agent's edit: ask
        case .missing:   // moved or deleted (git mv, a rename): writing would bring the old file back beside the new one
            let a = NSAlert(); a.messageText = String(localized: "“\(title)” was moved or deleted")
            a.informativeText = String(localized: "Save writes it at its old place again.")
            a.addButton(withTitle: String(localized: "Save Here")); a.addButton(withTitle: String(localized: "Cancel"))
            return await runSheet(a) == .alertFirstButtonReturn && write()
        default: return true
        }
    }

    /// Autosave writes only when that's safe; a conflict asks (if the tab is on screen), a missing file waits for ⌘S.
    private func autosaveNow() {
        guard let e = editor else { return }
        if isRemote { write(); return }
        switch FileSync.save(buffer: e.text, saved: lastSaved, disk: disk) {
        case .write: write()
        case .conflict: apply(disk)
        default: break
        }
    }

    @discardableResult
    private func write() -> Bool {
        guard let e = editor else { return true }
        if isRemote { writeRemote(); return true }
        // Through a symlink to the file it points at: an atomic write to the link would replace it with a plain file.
        do {
            try e.text.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
            lastSaved = e.text; gone = false; known = Stamp(path).map { ($0, e.text) }
        }
        catch { Banner.show(String(localized: "Couldn't save \(title): \(error.localizedDescription)"), style: .error); return false }
        editedStateMayHaveChanged()
        return true
    }

    /// Closing with a save: a remote file's tab waits until the host has it, and stays (with its edits) when that failed.
    private func writeAndClose() async -> Bool {
        guard isRemote else { return write() }
        writeRemote(); await saving?.value
        return !isEdited
    }

    var pendingSave: Task<Void, Never>? { saving }

    /// Each save waits for the one before, so it's checked against what that one wrote, not what's in flight.
    /// It holds the tab: one closed (or its workspace) right after Save still gets written.
    private func writeRemote() {
        let previous = saving
        saving = Task { [self] in
            await previous?.value
            guard let e = editor, e.text != lastSaved else { return }
            let text = e.text
            let res = await AppModel.shared.tryCall(FilesWriteRemote(path: path, text: text, base: lastSaved))
            if let error = res.error { Banner.show(String(localized: "Couldn't save \(title): \(error)"), style: .error); return }
            if let now = res.value??.changed { askKeepMine(disk: now); return }
            lastSaved = text; editedStateMayHaveChanged()
        }
    }

    private func editedStateMayHaveChanged() {
        let now = editor.map { $0.text != lastSaved } ?? false
        guard now != isEdited else { return }
        isEdited = now; onChange?()
    }

    /// A file event: read again only what changed, and off the main thread (a log a dev server appends to sends one every
    /// quarter second). One read at a time; events meanwhile make one more.
    private func diskChanged() {
        guard editor != nil, !isRemote else { return }
        if reading { readAgain = true; return }
        guard let now = Stamp(path) else { apply(.missing); return }
        if let known, known.stamp == now { return }   // touched, not changed (or our own write)
        guard Self.unopenable(path) == nil else { return }   // grown past the limit (a log) or a pipe now: keep what's shown
        reading = true
        let url = url
        Task { [weak self] in
            let text = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
            guard let self else { return }
            reading = false
            known = (now, text)
            apply(.present(text))
            if readAgain { readAgain = false; diskChanged() }
        }
    }

    private func apply(_ d: FileSync.Disk) {
        guard let e = editor else { return }
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
            guard let text = self?.editor?.text, await LSPManager.shared.open(root: r, path: p, text: text, retry: { [weak self] in self?.startLSP() }),
                  let self, let e = editor else { return }
            lspOpenedOn = AppModel.shared.connections
            e.completionProvider = { line, col in
                await LSPManager.shared.completion(root: r, path: p, line: line, column: col).map { CodeEditor.Completion(label: $0.label, detail: $0.detail, insert: $0.insert) }
            }
        }
    }

    /// LSP: definition of the symbol at the cursor, opened as a tab.
    func jumpToDefinition() {
        guard let e = editor, let (l, c) = e.cursor else { return }
        let p = path, r = root
        Task {
            guard let loc = await LSPManager.shared.definition(root: r, path: p, line: l, column: c) else { NSSound.beep(); return }
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
            symbol = await LSPManager.shared.symbol(root: root, path: path, line: line) ?? LanguageSpec.word(in: editor?.text ?? "", line: line, column: column)
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

    /// Why `p` (followed through symlinks) isn't opened; nil when it is, or when it's missing (said elsewhere). Binary is
    /// known only once it's read. A remote project's host applies the same rule (`files.readRemote`).
    static func unopenable(_ p: String) -> Unopenable? {
        var st = stat()
        guard stat(p, &st) == 0 else { return nil }
        if st.st_mode & S_IFMT != S_IFREG { return .special }
        return st.st_size > Unopenable.openLimit ? .tooBig(Int(st.st_size)) : nil
    }

    /// What the tab says instead of the text, for a file here or on a host.
    static func reason(_ u: Unopenable) -> String {
        switch u {
        case .special: String(localized: "Kelp opens files, not devices or pipes.")
        case .tooBig(let n):
            String(localized: "Too big to open here (\(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file))). Open it with another app.")
        case .binary: String(localized: "Binary file — open it with another app.")
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
