import AppKit
import Foundation
import Testing
import WorkbenchKit
@testable import KelpApp

/// A file tab as an agent and the user share it: the agent's change shows when nothing is edited here, ⌘S writes the
/// user's edit, and never over a change the agent made meanwhile.
extension SharedAppModel {
    private func file(_ text: String) throws -> String {
        let dir = testHome + "/files-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = dir + "/notes.txt"
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    @Test func anAgentsChangeShowsWhenNothingIsEditedHere() async throws {
        let p = try file("one\n")
        let tab = FileTab(uri: TabURI.file(p))
        #expect(tab.editor?.text == "one\n")
        try "two\n".write(toFile: p, atomically: true, encoding: .utf8)   // the agent
        for _ in 0..<100 where tab.editor?.text != "two\n" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(tab.editor?.text == "two\n")
    }

    @Test func saveWritesTheEditButNeverOverAnAgentsChange() async throws {
        let p = try file("one\n")
        let tab = FileTab(uri: TabURI.file(p))
        tab.editor?.setText("mine\n")
        #expect(await tab.save())
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        tab.editor?.setText("mine again\n")
        try "theirs\n".write(toFile: p, atomically: true, encoding: .utf8)   // the agent, before ⌘S
        #expect(await !tab.save())   // asks (here: no window, so it just doesn't write)
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "theirs\n")
    }

    /// Closing a workspace with an edited file: Cancel keeps it, Save writes it, Don't Save leaves nothing edited (so the
    /// workspace going away doesn't ask again); without Cancel the second button is Don't Save. Then what's left to wait
    /// for (a remote file's save) is nothing.
    @Test func closingAWorkspaceAsksAboutItsUnsavedFiles() async throws {
        let p = try file("one\n")
        let tab = FileTab(uri: TabURI.file(p)), untitled = UntitledTab(uri: "untitled:1")
        func type(_ t: String) { tab.editor?.setText(t); tab.editor?.onChange?(t) }   // as typing does
        type("mine\n")
        #expect(await !UnsavedChanges.settle([tab], .alertSecondButtonReturn))   // Cancel
        #expect(tab.isEdited)
        #expect(await UnsavedChanges.settle([tab], .alertFirstButtonReturn))     // Save
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        type("mine again\n")
        #expect(tab.isEdited)
        #expect(await UnsavedChanges.settle([tab], .alertThirdButtonReturn))     // Don't Save
        #expect(!tab.isEdited)
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        untitled.editor.setText("draft")
        #expect(await UnsavedChanges.settle([untitled], .alertSecondButtonReturn, canCancel: false))   // Don't Save, no Cancel
        #expect(!untitled.isEdited)
        #expect(await UnsavedChanges.written([tab, untitled]))
    }

    /// The shell reaches a file tab only as `TabContent`: what it asks must be the tab's own answer, not the protocol's
    /// "not this one" default (a signature that drifts would fall back to it silently).
    @Test func theShellSeesAFileTabThroughTabContent() async throws {
        let p = try file("a\nb\nc\nd\n")
        let file = FileTab(uri: TabURI.file(p))
        let tab: TabContent = file
        #expect(tab.fileURL == URL(fileURLWithPath: p))
        #expect(!tab.isTerminal && tab.terminalGrid == nil && tab.attention == nil)
        tab.goTo(line: 3)
        #expect(file.editor?.cursor?.line == 3)
        #expect(await tab.close())   // nothing edited: closes without asking
    }

    /// A 60 MB log or a pipe isn't read whole on the main thread: the tab says why instead (a pipe used to block forever,
    /// /dev/zero to eat memory). A terminal path that's a pipe isn't a file to preview either.
    @Test func hugeFilesAndPipesAreNotReadIntoTheEditor() throws {
        let p = try file("")
        #expect(truncate(p, 60 << 20) == 0)   // sparse: no 60 MB written
        #expect(FileTab(uri: TabURI.file(p)).editor == nil)
        let fifo = (p as NSString).deletingLastPathComponent + "/out.log"
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(FileTab(uri: TabURI.file(fifo)).editor == nil)
        #expect(TerminalPaths.resolve("out.log", cwd: (fifo as NSString).deletingLastPathComponent) == nil)
        #expect(TerminalPaths.resolve("notes.txt", cwd: (fifo as NSString).deletingLastPathComponent) != nil)
    }

    /// A file event reads the file again only when its stamp (size, modification time, inode) changed: every event of a
    /// log a dev server appends to used to read all of it on the main thread. Rewritten in place with the same size and
    /// its old modification time put back, the file looks untouched, so the tab keeps what it read.
    @Test func aFileEventWithTheSameStampReadsNothing() async throws {
        let p = try file("aaaa\n")
        let tab = FileTab(uri: TabURI.file(p))
        var st = stat()
        #expect(stat(p, &st) == 0)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: p))
        try h.write(contentsOf: Data("bbbb\n".utf8)); try h.close()   // same inode, same size
        var times = [st.st_atimespec, st.st_mtimespec]
        #expect(utimensat(AT_FDCWD, p, &times, 0) == 0)
        try await Task.sleep(for: .seconds(1))   // the events of both arrive meanwhile
        #expect(tab.editor?.text == "aaaa\n")
        try "cccc\n".write(toFile: p, atomically: true, encoding: .utf8)   // a real change still shows
        for _ in 0..<100 where tab.editor?.text != "cccc\n" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(tab.editor?.text == "cccc\n")
    }
}

/// Files moved in the Files panel come back with ⌘Z (and go again with ⇧⌘Z): an agent's folder isn't left half-moved.
extension SharedAppModel {
    @Test func aMoveInTheFilesPanelIsUndone() throws {
        let dir = URL(fileURLWithPath: testHome + "/moves-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("sub/a.txt")
        try "x".write(to: a, atomically: true, encoding: .utf8)
        let panel = FilesPanel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentViewController = panel
        let undo = try #require(panel.undoManager)
        #expect(panel.move([(a, b)], undo: "Move"))
        #expect(FileManager.default.fileExists(atPath: b.path) && !FileManager.default.fileExists(atPath: a.path))
        undo.undo()
        #expect(FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: b.path))
        undo.redo()
        #expect(FileManager.default.fileExists(atPath: b.path))
    }
}
