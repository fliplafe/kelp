import AppKit
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
@Test func programsDontWriteTheClipboard() {
    #expect(GhosttyRuntime.overrides.contains("clipboard-write = deny"))
}
#endif
