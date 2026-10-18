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

@Test func chatStreamParsing() {
    let lines = [
        #"{"type":"system","subtype":"init","model":"claude-opus-5-5","session_id":"s1","tools":[]}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Plan:"},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"Sources/App.swift","old_string":"a","new_string":"b"}}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"TodoWrite","input":{"todos":[{"content":"Add tests","status":"completed"},{"content":"Fix bug","status":"in_progress"}]}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":false}]}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.0123,"num_turns":3,"result":"done"}"#,
    ]
    let ev = lines.flatMap { ChatEvent.parse(Data($0.utf8)) }
    #expect(ev[0] == .started(model: "claude-opus-5-5", sessionId: "s1"))
    #expect(ev[1] == .text("Plan:"))
    #expect(ev[2] == .tool(id: "t1", name: "Edit", summary: "Edit Sources/App.swift"))
    #expect(ev[3] == .todos([.init(text: "Add tests", state: "completed"), .init(text: "Fix bug", state: "in_progress")]))
    #expect(ev[4] == .toolResult(id: "t1", ok: true, preview: "ok"))
    #expect(ev[5] == .finished(ok: true, costUSD: 0.0123, turns: 3))
    let u = String(decoding: ChatEvent.userLine("hi"), as: UTF8.self)
    #expect(u.hasSuffix("\n") && u.contains(#""type":"user""#))
}

@Test func claudeLimitMessagesParse() {
    let a = ClaudeLimits.parse("⏵⏵ auto mode on · You've used 80% of your weekly limit · resets Oct 20 at 5am (Europe/Helsinki)")
    #expect(a == [.init(kind: "weekly", percent: 80, resets: "Oct 20 at 5am")])
    let b = ClaudeLimits.parse("You've used 93% of your session limit · resets 3pm")
    #expect(b.first?.kind == "session" && b.first?.percent == 93 && b.first?.resets == "3pm")
    #expect(ClaudeLimits.parse("5-hour limit reached ∙ resets 11pm").first?.percent == 100)
    #expect(ClaudeLimits.parse("nothing to see").isEmpty)
}
