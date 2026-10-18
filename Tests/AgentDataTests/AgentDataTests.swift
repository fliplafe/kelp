import Foundation
import Testing
@testable import AgentData

private func tmp() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("agentdata-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@discardableResult
private func write(_ dir: URL, _ name: String, _ lines: [Any]) throws -> URL {
    let u = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    var d = Data()
    for l in lines {
        d += try (l as? String).map { Data($0.utf8) } ?? JSONSerialization.data(withJSONObject: l, options: .withoutEscapingSlashes)
        d += Data("\n".utf8)
    }
    try d.write(to: u)
    return u
}

private func date(_ s: String) -> Date { JSONL.date(s) ?? .distantPast }

private func user(_ content: Any, _ ts: String, sid: String = "s1", meta: Bool = false) -> [String: Any] {
    ["type": "user", "sessionId": sid, "cwd": "/work/demo", "timestamp": ts, "isMeta": meta, "message": ["role": "user", "content": content]]
}

private func assistant(_ id: String, _ req: String, _ ts: String, model: String = "claude-opus-5-5", text: String = "ok",
                       usage: [String: Int] = ["input_tokens": 10, "output_tokens": 20, "cache_creation_input_tokens": 30, "cache_read_input_tokens": 40]) -> [String: Any] {
    ["type": "assistant", "sessionId": "s1", "timestamp": ts, "requestId": req,
     "message": ["id": id, "role": "assistant", "model": model, "content": [["type": "text", "text": text]], "usage": usage]]
}

@Test func claudeSessionTitles() throws {
    let root = try tmp(), p = root.appendingPathComponent("-work-demo")
    let long = "  Fix the\n login   bug " + String(repeating: "a", count: 100)
    try write(p, "s1.jsonl", [
        ["type": "mode", "mode": "normal", "sessionId": "s1"],
        "not json {",
        user("<local-command-caveat>caveat</local-command-caveat>", "2026-10-18T10:00:00.000Z", meta: true),
        user("<command-name>/clear</command-name>", "2026-10-18T10:00:01.000Z"),
        user([["type": "text", "text": long]], "2026-10-18T10:00:02.000Z"),
        assistant("m1", "r1", "2026-10-18T10:00:05.000Z"),
        user([["type": "tool_result", "content": "x"]], "2026-10-18T10:05:00.000Z"),
    ])
    try write(p, "s2.jsonl", [["type": "summary", "summary": "Summarized work", "leafUuid": "x"], user("hello", "2026-10-17T09:00:00Z", sid: "s2")])
    try write(p, "s3.jsonl", [
        user("first prompt", "2026-10-16T09:00:00.000Z", sid: "s3"),
        ["type": "ai-title", "aiTitle": "AI title", "sessionId": "s3"],
        ["type": "custom-title", "customTitle": "Named by hand", "sessionId": "s3"],
    ])
    try write(p, "s4.jsonl", [user("<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>ship it</command-args>", "2026-10-15T09:00:00Z", sid: "s4")])
    try write(p, "s1/subagents/agent-a.jsonl", [user("sub", "2026-10-18T11:00:00.000Z", sid: "s1")])
    try write(p, "empty.jsonl", [["type": "mode", "mode": "normal"]])

    let s = ClaudeHistory.sessions(root: root)
    #expect(s.map(\.id) == ["s1", "s2", "s3", "s4"])
    #expect(s[0].title.hasPrefix("Fix the login bug aaa"))
    #expect(s[0].title.count == 80 && s[0].title.hasSuffix("…"))
    #expect(s[0].cwd == "/work/demo" && s[0].agent == .claude && s[0].messageCount == 5)
    #expect(s[0].started == date("2026-10-18T10:00:00.000Z") && s[0].updated == date("2026-10-18T10:05:00.000Z"))
    #expect(s[1].title == "Summarized work")
    #expect(s[2].title == "Named by hand")
    #expect(s[3].title == "/goal ship it")
}

@Test func claudeLargeFileReadsHeadAndTail() throws {
    let root = try tmp(), p = root.appendingPathComponent("-work-big")
    let pad = String(repeating: "x", count: 1000)
    var lines: [Any] = [user("big task", "2026-10-18T08:00:00.000Z")]
    for i in 0..<300 { lines.append(assistant("m\(i)", "r\(i)", "2026-10-18T09:00:00.000Z", text: pad)) }
    lines.append(assistant("last", "last", "2026-10-18T12:34:56.000Z"))
    lines.append(["type": "ai-title", "aiTitle": "Tail title", "sessionId": "s1"])
    try write(p, "s1.jsonl", lines)

    let s = try #require(ClaudeHistory.sessions(root: root).first)
    #expect(s.title == "Tail title")
    #expect(s.started == date("2026-10-18T08:00:00.000Z") && s.updated == date("2026-10-18T12:34:56.000Z"))
    #expect((200...400).contains(s.messageCount))
}

@Test func claudeUsageDedupes() throws {
    let root = try tmp(), p = root.appendingPathComponent("-work-demo")
    let a = assistant("m1", "r1", "2026-10-18T10:00:00.000Z")
    try write(p, "s1.jsonl", [a, a, assistant("m2", "r2", "2026-10-18T10:01:00.000Z", model: "claude-sonnet-5-5"),
                              assistant("m3", "r3", "2026-10-18T10:02:00.000Z", model: "<synthetic>"), user("hi", "2026-10-18T10:00:00.000Z")])
    try write(p, "s1/subagents/agent-a.jsonl", [a, assistant("m4", "r4", "2026-10-18T10:03:00.000Z")])
    let u = ClaudeUsage(root: root, since: date("2026-10-01T00:00:00Z"))
    #expect(u.entries.count == 3)
    #expect(u.entries.reduce(TokenCounts()) { $0 + $1.tokens } == TokenCounts(input: 30, output: 60, cacheWrite: 90, cacheRead: 120))
    #expect(ClaudeUsage(root: root, since: date("2026-10-18T10:00:30Z")).entries.count == 2)
}

@Test func fiveHourBlocks() throws {
    let t = TokenCounts(input: 1_000_000)
    func e(_ s: String, _ m: String = "claude-opus-5-5") -> ClaudeUsage.Entry { .init(timestamp: date(s), model: m, tokens: t) }
    let u = ClaudeUsage(entries: [
        e("2026-10-08T12:00:00Z"), e("2026-10-15T09:00:00Z"),
        e("2026-10-18T11:00:00Z"), e("2026-10-18T10:20:00Z", "claude-sonnet-5-5"), e("2026-10-18T14:30:00Z"),
        e("2026-10-18T15:10:00Z"), e("2026-10-18T22:00:00Z"),
    ])
    let blocks = u.blocks().suffix(3)
    #expect(blocks.map(\.start) == ["2026-10-18T10:00:00Z", "2026-10-18T15:00:00Z", "2026-10-18T22:00:00Z"].map(date))
    let first = try #require(blocks.first)
    #expect(first.end == date("2026-10-18T15:00:00Z") && first.tokens.input == 3_000_000)
    #expect(first.models == ["claude-opus-5-5", "claude-sonnet-5-5"])
    #expect(abs(first.estimatedCostUSD - (4 + 4 + 2)) < 1e-9)

    let b = try #require(u.currentBlock(now: date("2026-10-18T16:00:00Z")))
    #expect(b.start == date("2026-10-18T15:00:00Z") && b.end == date("2026-10-18T20:00:00Z") && b.tokens.input == 1_000_000)
    #expect(u.currentBlock(now: date("2026-10-18T21:00:00Z")) == nil)
    #expect(u.currentBlock(now: date("2026-10-18T22:30:00Z"))?.end == date("2026-10-19T03:00:00Z"))

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = try #require(TimeZone(identifier: "UTC"))
    #expect(u.today(now: date("2026-10-18T23:00:00Z"), calendar: utc).tokens.input == 5_000_000)
    #expect(u.last7Days(now: date("2026-10-18T23:00:00Z"), calendar: utc).tokens.input == 6_000_000)
}

@Test func pricingMath() {
    let m = TokenCounts(input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
    #expect(abs(Pricing.cost(model: "claude-opus-5-5", tokens: m) - 29.2) < 1e-9)
    #expect(abs(Pricing.cost(model: "claude-opus-5-5[1m]", tokens: TokenCounts(input: 500, output: 100)) - 0.004) < 1e-12)
    #expect(Pricing.forModel("claude-opus-4-8")?.input == 5)
    #expect(Pricing.forModel("claude-sonnet-4-6")?.input == 3)
    #expect(Pricing.forModel("claude-sonnet-5-5")?.input == 2)
    #expect(Pricing.forModel("claude-fable-5-1")?.cacheRead == 0.25)
    #expect(Pricing.forModel("claude-fable-5")?.cacheRead == 1)
    #expect(Pricing.forModel("claude-haiku-4-5")?.input == 1)
    #expect(Pricing.forModel("gpt-5.1-codex-mini")?.input == 0.25)
    #expect(Pricing.forModel("gpt-5.2-codex")?.output == 14)
    #expect(Pricing.forModel("gpt-5.5")?.input == 1.25)
    #expect(Pricing.cost(model: "llama-3", tokens: m) == 0)
}

@Test func codexSessionsAndLimits() throws {
    let root = try tmp()
    let id1 = "019f47f3-8f9b-7823-98a3-9195ae68d901", id2 = "019f47f3-8f9b-7823-98a3-9195ae68d902"
    func item(_ role: String, _ text: String, _ ts: String) -> [String: Any] {
        ["timestamp": ts, "type": "response_item", "payload": ["type": "message", "role": role, "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]]]
    }
    func tokens(_ ts: String, _ rl: Any) -> [String: Any] {
        ["timestamp": ts, "type": "event_msg", "payload": ["type": "token_count", "info": NSNull(), "rate_limits": rl]]
    }
    let f1 = try write(root, "2026/10/17/rollout-2026-10-17T10-00-00-\(id1).jsonl", [
        ["timestamp": "2026-10-17T10:00:00.100Z", "type": "session_meta", "payload": ["id": id1, "cwd": "/work/a", "timestamp": "2026-10-17T10:00:00.000Z"]],
        item("user", "# AGENTS.md instructions for /work/a", "2026-10-17T10:00:01.000Z"),
        item("user", "<environment_context><cwd>/work/a</cwd></environment_context>", "2026-10-17T10:00:01.000Z"),
        ["timestamp": "2026-10-17T10:00:02.000Z", "type": "event_msg", "payload": ["type": "user_message", "message": "Refactor the parser"]],
        item("user", "Refactor the parser", "2026-10-17T10:00:02.000Z"),
        item("assistant", "Done", "2026-10-17T10:01:00.000Z"),
        tokens("2026-10-17T10:01:00.000Z", ["primary": ["used_percent": 12.5, "window_minutes": 300, "resets_at": 1_792_000_000],
                                             "secondary": ["used_percent": 40, "window_minutes": 10080, "resets_at": 1_792_500_000]]),
        tokens("2026-10-17T10:02:00.000Z", ["primary": NSNull(), "secondary": NSNull(), "credits": NSNull()]),
    ])
    try write(root, "2026/10/18/rollout-2026-10-18T09-00-00-\(id2).jsonl", [
        ["timestamp": "2026-10-18T09:00:00.000Z", "type": "session_meta", "payload": ["id": id2, "cwd": "/work/b", "timestamp": "2026-10-18T09:00:00.000Z"]],
        item("user", "Old shape please", "2026-10-18T09:00:01.000Z"),
        tokens("2026-10-18T09:05:00.000Z", ["primary": ["used_percent": 50, "window_minutes": 300, "resets_in_seconds": 600]]),
    ])

    let s = CodexHistory.sessions(root: root)
    #expect(s.map(\.id) == [id2, id1])
    #expect(s[1].title == "Refactor the parser" && s[1].cwd == "/work/a" && s[1].messageCount == 4 && s[1].agent == .codex)
    #expect(s[0].title == "Old shape please")

    let l1 = try #require(CodexUsage.latest(in: f1))
    #expect(l1 == CodexLimits(primaryUsedPercent: 12.5, primaryResetsAt: Date(timeIntervalSince1970: 1_792_000_000),
                              secondaryUsedPercent: 40, secondaryResetsAt: Date(timeIntervalSince1970: 1_792_500_000),
                              observedAt: date("2026-10-17T10:01:00.000Z")))
    let l = try #require(CodexUsage.latest(root: root))
    #expect(l.observedAt == date("2026-10-18T09:05:00.000Z") && l.primaryUsedPercent == 50)
    #expect(l.primaryResetsAt == date("2026-10-18T09:15:00.000Z") && l.secondaryUsedPercent == nil)

    let flat = CodexUsage.limits(tokens("2026-10-18T09:05:00Z", ["primary_used_percent": 7, "secondary_used_percent": 3]))
    #expect(flat?.primaryUsedPercent == 7 && flat?.secondaryUsedPercent == 3)
}

@Test func searchAndResume() throws {
    let root = try tmp(), p = root.appendingPathComponent("-work-demo")
    try write(p, "a.jsonl", [user("deploy the app", "2026-10-18T10:00:00Z", sid: "a"), assistant("m1", "r1", "2026-10-18T10:01:00Z", text: "the flux capacitor is fine")])
    try write(p, "b.jsonl", [user("write docs", "2026-10-18T11:00:00Z", sid: "b"), assistant("m2", "r2", "2026-10-18T11:01:00Z", text: "nothing here")])
    let s = ClaudeHistory.sessions(root: root)
    #expect(History.search(s, query: "DEPLOY").map(\.id) == ["a"])
    #expect(History.search(s, query: "/work/demo").count == 2)
    #expect(History.search(s, query: " ").count == 2)
    #expect(History.fullTextSearch(query: "Flux Capacitor", in: s).map(\.id) == ["a"])
    #expect(History.fullTextSearch(query: "the", in: s, limit: 1).count == 1)
    #expect(History.fullTextSearch(query: "", in: s).isEmpty)

    #expect(History.resumeCommand(for: s[0]) == ["claude", "--resume", s[0].id])
    var codex = s[0]
    codex.agent = .codex
    #expect(History.resumeCommand(for: codex) == ["codex", "resume", s[0].id])
}

@Test func missingDirsAreEmpty() {
    let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    #expect(ClaudeHistory.sessions(root: nowhere).isEmpty)
    #expect(CodexHistory.sessions(root: nowhere).isEmpty)
    #expect(ClaudeUsage(root: nowhere).entries.isEmpty)
    #expect(CodexUsage.latest(root: nowhere) == nil)
}
