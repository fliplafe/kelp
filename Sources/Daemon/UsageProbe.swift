import Foundation
import Core
import Agents

/// Plan limits as the agents themselves show them in `/usage` (Claude Code, Grok Build, Antigravity). A hidden copy of
/// the agent opens that screen now and then and quits: no tokens are spent and Kelp never touches their credentials.
extension Daemon {
    struct PlanProbe: Sendable {
        let agent: String, command: String, every: TimeInterval
        let ready: @Sendable (String) -> Bool    // its prompt is drawn
        let shown: @Sendable (String) -> Bool    // the usage screen has loaded
        let parse: @Sendable (String) -> [ClaudeLimits.Reading]
    }
    struct PlanState { var readings: [ClaudeLimits.Reading] = []; var at: Date?; var running = false; var readAt: Date? }

    static let planProbes = [
        PlanProbe(agent: "claude", command: "claude", every: 600, ready: { $0.contains("❯") },
                  shown: { $0.contains("Current week") && $0.contains("% used") }, parse: ClaudeLimits.parseUsageScreen),
        PlanProbe(agent: "grok", command: "grok", every: 1800, ready: { $0.contains("Ctrl+x:shortcuts") },
                  shown: { $0.contains("Weekly limit") && $0.contains("Resets") }, parse: ClaudeLimits.parseGrokUsage),
        PlanProbe(agent: "antigravity", command: "agy", every: 1800, ready: { $0.contains("for shortcuts") },
                  shown: { $0.contains("Weekly Limit Remaining") && $0.contains("%") }, parse: ClaudeLimits.parseAntigravityUsage)
    ]

    func refreshPlansIfStale() {
        guard (settings["usage.readPlans"] ?? settings["usage.readClaudePlan"])?.bool != false else { return }
        for probe in Self.planProbes {
            let start: Bool = lock.withLock {
                let s = plans[probe.agent] ?? PlanState()
                guard !s.running, Date().timeIntervalSince(s.at ?? .distantPast) > probe.every else { return false }
                plans[probe.agent, default: PlanState()].running = true; return true
            }
            guard start else { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                var readings: [ClaudeLimits.Reading] = []
                if let path = try? LoginPath.resolve(probe.command), let cwd = probeDir(probe.agent) {
                    var screen = ""
                    for argv in probeArgv(probe.agent, path) {
                        (readings, screen) = Self.probe(probe, argv: argv, cwd: cwd)
                        if !readings.isEmpty { break }
                    }
                    // What a failed probe saw, for whoever fixes the parser when an agent changes its screen.
                    if readings.isEmpty, (try? Paths.ensure(root.appendingPathComponent("probe"))) != nil { try? screen.write(to: root.appendingPathComponent("probe/\(probe.agent).txt"), atomically: true, encoding: .utf8) }
                }
                lock.withLock {
                    if !readings.isEmpty { plans[probe.agent]?.readings = readings; plans[probe.agent]?.readAt = Date() }
                    // A failed probe retries in 2 minutes rather than waiting a whole round.
                    plans[probe.agent]?.at = readings.isEmpty ? Date().addingTimeInterval(120 - probe.every) : Date()
                    plans[probe.agent]?.running = false
                }
            }
        }
    }

    /// A turn just ended, so the agent's usage moved: read its plan half a minute from now instead of at the next round
    /// (up to 10 minutes late for Claude). The UI's next `usage.get` starts the read.
    func planUsed(_ agent: String) {
        guard let p = Self.planProbes.first(where: { $0.agent == agent }) else { return }
        lock.withLock {
            guard let at = plans[agent]?.at else { return }
            plans[agent]?.at = min(at, Date().addingTimeInterval(30 - p.every))
        }
    }

    /// A folder the agent already works in, so it won't ask whether to trust it. Grok doesn't ask, but keeps a session
    /// per launch: it gets Kelp's own folder and always the same session, so its history doesn't fill up.
    private func probeDir(_ agent: String) -> String? {
        if agent == "grok" {
            let d = root.appendingPathComponent("probe"); try? Paths.ensure(d); return d.path
        }
        let used = ((try? store.sessions()) ?? []).filter { $0.agent == agent }.sorted { $0.createdAt > $1.createdAt }.map(\.cwd)
        let trusted = agent == "antigravity" ? Self.antigravityTrusted() : []
        return (used + trusted).first { FileManager.default.fileExists(atPath: $0) }
    }

    private func probeArgv(_ agent: String, _ path: String) -> [[String]] {
        guard agent == "grok" else { return [[path]] }
        let file = root.appendingPathComponent("probe/grok-session")
        let id = (try? String(contentsOf: file, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? UUID().uuidString.lowercased()
        try? id.write(to: file, atomically: true, encoding: .utf8)
        return [[path, "--resume", id], [path, "--session-id", id]]   // the first run creates it
    }

    /// Folders the user trusted in Antigravity (read only).
    private static func antigravityTrusted() -> [String] {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return o["trustedWorkspaces"] as? [String] ?? []
    }

    static func probe(_ p: PlanProbe, argv: [String], cwd: String) -> ([ClaudeLimits.Reading], String) {
        let screen = ScreenBuffer()
        guard let pty = try? PTY(argv: argv, cwd: cwd, env: ["PATH": LoginPath.value], cols: 120, rows: 80) else { return ([], "") }
        pty.onOutput = { screen.append($0) }
        defer { pty.terminate() }
        // Ready: the prompt is drawn and output went quiet (or it failed and said so).
        guard screen.wait(20, until: { (p.ready($0) && screen.quietFor > 1) || $0.contains("Error:") }),
              p.ready(StatusDetector.stripANSI(screen.text)) else { return ([], StatusDetector.stripANSI(screen.text)) }
        pty.write(Data("/usage".utf8)); Thread.sleep(forTimeInterval: 0.6); pty.write(Data("\r".utf8))
        _ = screen.wait(20) { p.shown($0) && screen.quietFor > 1.5 }
        pty.write(Data("\u{1B}".utf8))
        let text = StatusDetector.stripANSI(screen.text).replacingOccurrences(of: "\r", with: "\n")
        return (p.parse(text), text)
    }
}

/// Output collected from a probe's PTY.
private final class ScreenBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var last = Date()
    func append(_ d: Data) { lock.withLock { data.append(d); last = Date() } }
    // swiftlint:disable:next optional_data_string_conversion
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }   // lossy on purpose: TUI output
    var quietFor: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
    func wait(_ seconds: TimeInterval, until ok: (String) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if ok(StatusDetector.stripANSI(text)) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
