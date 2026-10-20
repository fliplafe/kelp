import AppKit
import Core
import Quartz
import GitKit
import Markdown
import WorkbenchKit

/// File operations, each undoable with ⌘Z.
extension FilesPanel {
    // MARK: file operations, each one undoable with ⌘Z (as moves: trashing is a move into the Trash)
    // Moves and trashing are renames on the same volume (instant) and stay synchronous, so undo/redo register in their
    // own undo group; copying a folder dropped from Finder can take minutes and runs off the main thread.

    /// Moves each `from → to`; ⌘Z moves them back.
    @discardableResult func move(_ pairs: [(URL, URL)], undo name: String) -> Bool {
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

    func trash(_ urls: [URL], undo name: String) {
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
    func copy(_ urls: [URL], into dir: URL, undo name: String) {
        Task {
            let (made, failure) = await Task.detached { () -> ([URL], Error?) in
                var made: [URL] = []
                for u in urls {
                    let dst = Self.free(dir.appendingPathComponent(u.lastPathComponent))
                    do { try FileManager.default.copyItem(at: u, to: dst); made.append(dst) } catch { return (made, error) }
                }
                return (made, nil)
            }.value
            if let failure { showError(failure) }
            if !made.isEmpty { undoManager?.registerUndo(withTarget: self) { $0.trash(made, undo: name) }; undoManager?.setActionName(name) }
            reloadTree()
        }
    }

    /// `u`, or the first of "name copy.ext", "name copy 2.ext"… (`word: nil`: "name 2.ext") that doesn't exist.
    nonisolated static func free(_ u: URL, word: String? = "copy") -> URL {
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
        copy(urls, into: URL(fileURLWithPath: root).appendingPathComponent(selectedDir), undo: String(localized: "Paste"))
    }
}
