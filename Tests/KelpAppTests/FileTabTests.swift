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

    @Test func saveWritesTheEditButNeverOverAnAgentsChange() throws {
        let p = try file("one\n")
        let tab = FileTab(uri: TabURI.file(p))
        tab.editor?.setText("mine\n")
        #expect(tab.save())
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        tab.editor?.setText("mine again\n")
        try "theirs\n".write(toFile: p, atomically: true, encoding: .utf8)   // the agent, before ⌘S
        #expect(!tab.save())   // asks (here: no window, so it just doesn't write)
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "theirs\n")
    }

    /// Closing a workspace with an edited file: Cancel keeps it, Save writes it, Don't Save leaves nothing edited (so the
    /// workspace going away doesn't ask again); without Cancel the second button is Don't Save.
    @Test func closingAWorkspaceAsksAboutItsUnsavedFiles() throws {
        let p = try file("one\n")
        let tab = FileTab(uri: TabURI.file(p)), untitled = UntitledTab(uri: "untitled:1")
        func type(_ t: String) { tab.editor?.setText(t); tab.editor?.onChange?(t) }   // as typing does
        type("mine\n")
        #expect(!UnsavedChanges.settle([tab], .alertSecondButtonReturn))   // Cancel
        #expect(tab.isEdited)
        #expect(UnsavedChanges.settle([tab], .alertFirstButtonReturn))     // Save
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        type("mine again\n")
        #expect(tab.isEdited)
        #expect(UnsavedChanges.settle([tab], .alertThirdButtonReturn))     // Don't Save
        #expect(!tab.isEdited)
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "mine\n")
        untitled.editor.setText("draft")
        #expect(UnsavedChanges.settle([untitled], .alertSecondButtonReturn, canCancel: false))   // Don't Save, no Cancel
        #expect(!untitled.isEdited)
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
