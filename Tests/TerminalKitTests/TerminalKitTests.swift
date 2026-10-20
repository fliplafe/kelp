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
