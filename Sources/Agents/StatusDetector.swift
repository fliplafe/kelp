import Foundation
import Core

/// Derives agent status from output and idle time. Hook events always win over heuristics.
public struct StatusDetector: Sendable {
    public private(set) var status: AgentStatus = .idle
    private var lastOutput: Date?
    private var tail = ""
    private var hooked = false
    private let manifest: AgentManifest
    private let regexes: [NSRegularExpression]

    public init(manifest: AgentManifest) {
        self.manifest = manifest
        // Agents with hooks report every change themselves; guessing from output would call a TUI that redraws
        // its idle prompt "working" (a resumed Claude Code sits at its prompt until it gets a task).
        hooked = manifest.hooksSettingsFlag != nil
        regexes = manifest.waitingPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    public mutating func output(_ chunk: String, at now: Date = Date()) {
        lastOutput = now
        tail = String((tail + Self.stripANSI(chunk)).suffix(600))
        if !hooked, manifest.quietSeconds < 1e8 { status = .working }   // plain shells don't track status
    }

    /// Call periodically; returns the (possibly new) status.
    @discardableResult
    public mutating func tick(at now: Date = Date()) -> AgentStatus {
        guard !hooked, status == .working, let last = lastOutput, now.timeIntervalSince(last) >= manifest.quietSeconds else { return status }
        let r = NSRange(tail.startIndex..., in: tail)
        status = regexes.contains { $0.firstMatch(in: tail, range: r) != nil } ? .waiting : .done
        return status
    }

    /// Hook event: "working" | "waiting" | "done". Once seen, heuristics are off for this session.
    public mutating func hook(_ event: String) {
        hooked = true
        switch event {
        case "working": status = .working
        case "waiting": status = .waiting
        case "done": status = .done
        default: break
        }
    }

    public mutating func exited() { status = .exited }

    /// The user typed into the agent: whatever it asked before is answered, only what it prints next can ask again.
    public mutating func input() { tail = "" }

    /// A better guess from elsewhere (local model) that does not switch heuristics off like a hook does.
    public mutating func override(_ s: AgentStatus) { if status != .exited && status != .hibernated { status = s } else if s == .hibernated { status = s } }

    /// Removes an empty prompt's example text (Claude Code: `❯ Try "create a util logging.py…"`), which reads like a
    /// task the agent is doing to anyone summarizing the screen.
    public static func withoutPromptHints(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.range(of: #"^\s*[❯>›]\s*Try ""#, options: .regularExpression) == nil }
            .joined(separator: "\n")
    }

    public static func stripANSI(_ s: String) -> String {
        // TUIs often place words with cursor moves instead of spaces; keep a space there so text stays readable.
        s.replacingOccurrences(of: #"\x{1B}\[\d*[GC]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\x{1B}\[[0-9;?<>=]*[ -/]*[@-~]|\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)|\x{1B}[78=>]"#, with: "", options: .regularExpression)
    }
}
