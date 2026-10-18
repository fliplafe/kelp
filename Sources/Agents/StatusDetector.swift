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
        regexes = manifest.waitingPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    public mutating func output(_ chunk: String, at now: Date = Date()) {
        lastOutput = now
        tail = String((tail + Self.stripANSI(chunk)).suffix(600))
        if !hooked { status = .working }
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

    public static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]|\u{1B}\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)"#, with: "", options: .regularExpression)
    }
}
