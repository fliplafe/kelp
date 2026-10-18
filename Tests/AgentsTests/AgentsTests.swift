import Foundation
import Testing
import Core
@testable import Agents

@Test func heuristicWaitingVsDone() {
    let t0 = Date()
    var d = StatusDetector(manifest: .presets[0])
    d.output("\u{1B}[1mDo you want to proceed? [y/n]\u{1B}[0m", at: t0)
    #expect(d.status == .working)
    #expect(d.tick(at: t0.addingTimeInterval(1)) == .working)
    #expect(d.tick(at: t0.addingTimeInterval(4)) == .waiting)

    var e = StatusDetector(manifest: .presets[0])
    e.output("all done, 3 files changed", at: t0)
    #expect(e.tick(at: t0.addingTimeInterval(4)) == .done)
}

@Test func hooksOverrideHeuristics() {
    let t0 = Date()
    var d = StatusDetector(manifest: .presets[0])
    d.hook("working")
    d.output("whatever", at: t0)
    #expect(d.tick(at: t0.addingTimeInterval(60)) == .working)
    d.hook("done")
    #expect(d.status == .done)
}

@Test func manifestFilesOverridePresets() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONEncoder().encode(AgentManifest(id: "mine", name: "Mine", command: "mine-cli")).write(to: dir.appendingPathComponent("mine.json"))
    try Data("{bad".utf8).write(to: dir.appendingPathComponent("bad.json"))
    let all = AgentManifest.load(dir: dir)
    #expect(all.contains { $0.id == "mine" } && all.contains { $0.id == "claude" })
}

@Test func hooksSettingsIsValidJSON() throws {
    let v = try JSONDecoder().decode(JSONValue.self, from: Data(Hooks.settingsJSON().utf8))
    #expect(v["hooks"]?["Stop"] != nil)
}

@Test func trustMenuPicksYes() {
    // Claude Code 2026: cursor starts on "No, exit".
    let claude = """
     Quick safety check: Is this a project you created or one you trust?

     ❯ No, exit
       Yes, I trust this folder

     Enter to confirm · Esc to cancel
    """
    #expect(AgentManifest.AutoAnswer.menuKeys(screen: claude, choose: "(?i)(yes|trust)") == "\u{1B}[B\r")
    // Older layout: cursor already on yes.
    let older = "Do you trust the files in this folder?\n\n❯ 1. Yes, proceed\n  2. No, exit\n"
    #expect(AgentManifest.AutoAnswer.menuKeys(screen: older, choose: "(?i)(yes|trust)") == "\r")
    #expect(AgentManifest.AutoAnswer.menuKeys(screen: "Do you trust this folder? (loading)", choose: "(?i)yes") == nil)
}

@Test func stripKeepsWordGapsFromCursorMoves() {
    let raw = "\u{1B}[2GQuick\u{1B}[8Gsafety\u{1B}[15Gcheck: one\u{1B}[30Gyou trust?\n\u{1B}[2G\u{1B}[38;2;177;185;249m❯\u{1B}[4GNo,\u{1B}[8Gexit\u{1B}[39m\n\u{1B}[4GYes,\u{1B}[9GI\u{1B}[11Gtrust\n"
    let t = StatusDetector.stripANSI(raw)
    #expect(t.contains("one you trust"))
    #expect(AgentManifest.AutoAnswer.menuKeys(screen: t, choose: "(?i)(yes|trust)") == "\u{1B}[B\r")
}

@Test func cursorOptionHandlesCRLF() {
    // Real Claude Code bytes: options separated by "\r\r\n" (one Character in Swift).
    let raw = "\u{1B}[2G\u{1B}[38;2;177;185;249m❯\u{1B}[4GNo,\u{1B}[8Gexit\u{1B}[39m\r\r\n\u{1B}[4GYes,\u{1B}[9GI\u{1B}[11Gtrust\r\r\n"
    #expect(AgentManifest.AutoAnswer.optionAtCursor(StatusDetector.stripANSI(raw)) == "No, exit")
    // After moving down, Ink redraws just the two lines: the last ❯ is on Yes.
    let moved = raw + "\u{1B}[2A\u{1B}[4GNo,\u{1B}[8Gexit\r\r\n\u{1B}[2G❯\u{1B}[4GYes,\u{1B}[9GI\u{1B}[11Gtrust"
    #expect(AgentManifest.AutoAnswer.optionAtCursor(StatusDetector.stripANSI(moved)) == "Yes, I trust")
}
