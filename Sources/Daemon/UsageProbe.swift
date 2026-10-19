import Foundation
import Core
import Agents

/// Claude plan limits as Claude Code shows them in `/usage` (session, week, per model). A hidden Claude Code opens
/// that screen every 10 minutes and closes: no tokens are spent and Krill never touches Claude's credentials.
extension Daemon {
    static let planRefresh: TimeInterval = 600

    func refreshClaudePlanIfStale() {
        guard settings["usage.readClaudePlan"]?.bool != false, let claude = try? LoginPath.resolve("claude") else { return }
        let start: Bool = lock.withLock {
            guard !claudePlanRunning, Date().timeIntervalSince(claudePlanAt ?? .distantPast) > Self.planRefresh else { return false }
            claudePlanRunning = true; return true
        }
        guard start, let cwd = trustedClaudeDir() else { lock.withLock { claudePlanRunning = false }; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let readings = Self.probeClaudeUsage(claude, cwd: cwd)
            self?.lock.withLock {
                if !readings.isEmpty { self?.claudePlan = readings }
                // A failed probe retries in 2 minutes rather than 10.
                self?.claudePlanAt = readings.isEmpty ? Date().addingTimeInterval(120 - Self.planRefresh) : Date()
                self?.claudePlanRunning = false
            }
        }
    }

    /// A folder Claude Code already ran in (so it won't ask whether to trust it).
    private func trustedClaudeDir() -> String? {
        ((try? store.sessions()) ?? []).filter { $0.agent == "claude" }.sorted { $0.createdAt > $1.createdAt }
            .map(\.cwd).first { FileManager.default.fileExists(atPath: $0) }
    }

    static func probeClaudeUsage(_ claude: String, cwd: String) -> [ClaudeLimits.Reading] {
        let screen = ScreenBuffer()
        guard let pty = try? PTY(argv: [claude], cwd: cwd, env: ["PATH": LoginPath.value], cols: 120, rows: 60) else { return [] }
        pty.onOutput = { screen.append($0) }
        defer { pty.terminate() }
        // Ready: the prompt is drawn and output went quiet.
        guard screen.wait(15, until: { $0.contains("❯") && screen.quietFor > 1 }) else { return [] }
        pty.write(Data("/usage".utf8)); Thread.sleep(forTimeInterval: 0.4); pty.write(Data("\r".utf8))
        _ = screen.wait(20) { $0.contains("Current week") && $0.contains("% used") && screen.quietFor > 1.5 }
        pty.write(Data("\u{1B}".utf8))
        return ClaudeLimits.parseUsageScreen(StatusDetector.stripANSI(screen.text).replacingOccurrences(of: "\r", with: "\n"))
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
