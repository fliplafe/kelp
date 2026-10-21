import AppKit
import GhosttyKit
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

@MainActor
/// Programs may copy (OSC 52: Claude Code over ssh), flagged so that `confirmClipboard` keeps those lines from running on
/// ⌘V where pastes aren't bracketed — which needs paste protection on.
@Test func programCopiesAreFlagged() throws {
    #expect(GhosttyRuntime.overrides.contains("clipboard-write = ask"))
    #expect(GhosttyRuntime.overrides.contains("clipboard-paste-protection = true"))
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

/// ⌘ over a program that took the mouse gets ⇧, which is how Ghostty looks for links past the capture; nothing else changes.
@Test func commandFindsLinksPastMouseCapture() {
    let g = GhosttyTerminalView.self
    #expect(g.linkMods(.command, captured: true) == [.command, .shift])
    #expect(g.linkMods([.command, .capsLock], captured: true) == [.command, .capsLock, .shift])
    #expect(g.linkMods(.command, captured: false) == .command)   // a shell prompt: Ghostty wants ⌘ alone
    #expect(g.linkMods([.command, .option], captured: true) == [.command, .option])
    #expect(g.linkMods([], captured: true) == [])
}

/// A program that takes the mouse (as Claude Code does) and prints a link: ⌘-click on it opens its whole target.
@Test @MainActor func commandClickOpensALinkUnderMouseCapture() async throws {
    let script = #"printf '\033[?1000h\033[?1006h\033]8;;https://example.com/a?b=c\033\\LINKTEXT\033]8;;\033\\\n'; sleep 20"#
    let v = GhosttyTerminalView(command: script, cwd: NSTemporaryDirectory())
    let surface = try #require(v.surface)
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = v; w.orderFront(nil)
    defer { w.orderOut(nil) }
    var opened: URL?
    v.onOpenURL = { opened = $0 }
    let deadline = Date() + 5
    while !(v.visibleText.contains("LINKTEXT") && ghostty_surface_mouse_captured(surface)), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    let rows = v.visibleText.components(separatedBy: "\n")
    let row = try #require(rows.firstIndex { $0.contains("LINKTEXT") })
    let s = ghostty_surface_size(surface), scale = w.backingScaleFactor
    let cw = Double(s.cell_width_px) / scale, ch = Double(s.cell_height_px) / scale
    let p = v.convert(NSPoint(x: 12 + 3.5 * cw, y: v.bounds.height - 8 - (Double(row) + 0.5) * ch), to: nil)
    func send(_ t: NSEvent.EventType, _ mods: NSEvent.ModifierFlags, dx: Double = 0) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x + dx, y: p.y), modifierFlags: mods, timestamp: 0, windowNumber: w.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: t == .mouseMoved ? 0 : 1, pressure: 1))
    }
    v.mouseMoved(with: try send(.mouseMoved, [], dx: -3))
    v.mouseMoved(with: try send(.mouseMoved, .command))
    v.mouseDown(with: try send(.leftMouseDown, .command)); v.mouseUp(with: try send(.leftMouseUp, .command))
    #expect(opened?.absoluteString == "https://example.com/a?b=c")
}
