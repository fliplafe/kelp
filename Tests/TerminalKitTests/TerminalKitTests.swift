import AppKit
#if canImport(GhosttyKit)
import GhosttyKit
#endif
import SwiftTerm
import Testing
@testable import TerminalKit

@Test func copyLeavesTheTUIBehind() {
    // An agent's gutter and padding to the right edge.
    #expect(TerminalCopy.clean("  func a() {   \n      return 1\n  }  ") == "func a() {\n    return 1\n}")
    // A box: its sides go, the text stays.
    #expect(TerminalCopy.clean("│ npm test   │\n│ 3 passed   │") == "npm test\n3 passed")
    // Plain text is untouched.
    #expect(TerminalCopy.clean("a b\nc") == "a b\nc")
}

@Test func wordsKeepTheirLineNumbers() {
    let line = "  Edited Sources/App.swift:12:5, see (docs/x.md)."
    #expect(TerminalCopy.word(in: line, at: 12)?.text == "Sources/App.swift:12:5")
    #expect(TerminalCopy.word(in: line, at: 12)?.start == 9)
    #expect(TerminalCopy.word(in: line, at: 40)?.text == "docs/x.md")
    #expect(TerminalCopy.word(in: line, at: 1) == nil)
}

@Test func wideCharactersTakeTwoColumns() {
    let line = "日本 src/a.swift"   // 日本 covers columns 0-3, the path starts at 5
    #expect(TerminalCopy.word(in: line, at: 6)?.text == "src/a.swift")
    #expect(TerminalCopy.word(in: line, at: 6)?.start == 5)
    #expect(TerminalCopy.word(in: line, at: 1)?.width == 4)
    #expect(TerminalCopy.word(in: line, at: 4) == nil)
}

/// A link ⌘-clicked in the SwiftTerm terminal goes to the pane's handler (which opens pages and files only), never
/// straight to its app: an OSC 8 link can hide a cloned repo's tool.app behind any text.
@MainActor
@Test func aSwiftTermLinkGoesToTheHandler() {
    let t = RemoteTerminalView(frame: .zero)
    var got: URL?
    t.onOpenURL = { got = $0 }
    t.requestOpenLink(source: TerminalView(frame: .zero), link: "file:///tmp/tool.app", params: [:])
    #expect(got?.path == "/tmp/tool.app")
}

#if canImport(GhosttyKit)
@MainActor
/// Programs can't put text on the clipboard (OSC 52): it would run on the user's next ⌘V in a shell that takes no pastes.
@Test func programsDontWriteTheClipboard() throws {
    #expect(GhosttyRuntime.overrides.contains("clipboard-write = deny"))
    // And Ghostty takes every line of Kelp's settings (a wrong key or value would be dropped with a diagnostic).
    try #require(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS)   // config needs it; no app
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-overrides-\(UUID().uuidString).conf")
    try GhosttyRuntime.overrides.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let cfg = ghostty_config_new()
    ghostty_config_load_file(cfg, file.path); ghostty_config_finalize(cfg)
    let problems = (0..<ghostty_config_diagnostics_count(cfg)).map { String(cString: ghostty_config_get_diagnostic(cfg, $0).message) }
    ghostty_config_free(cfg)
    #expect(problems.isEmpty, "\(problems)")
}
#endif

@Test @MainActor func pasteTypesAnImageAsItsPath() throws {
    let pb = NSPasteboard(name: .init("kelp-test-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    let img = NSImage(size: NSSize(width: 4, height: 4))
    img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
    // A screenshot (an image and no text): a PNG on disk, typed as its path.
    pb.clearContents(); pb.writeObjects([img])
    let typed = try #require(TerminalPaste.text(from: pb))
    #expect(typed.hasSuffix(".png "))
    #expect(NSImage(contentsOfFile: String(typed.dropLast())) != nil)
    // Text wins over an image that came with it (a table copied from a spreadsheet).
    pb.clearContents(); pb.writeObjects([img, "a b" as NSString])
    #expect(TerminalPaste.text(from: pb) == "a b")
    // A file copied in Finder: its path, escaped, not just its name.
    pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: "/tmp/my shot.png") as NSURL])
    #expect(TerminalPaste.text(from: pb) == "/tmp/my\\ shot.png ")
}
