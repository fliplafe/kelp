import Foundation
import IOKit.pwr_mgt
import Core
import GitKit
import Agents

/// RPCs that chain several steps or wait on other processes.
extension Daemon {

    /// What a short command prints (stdout, then stderr), or nil if it fails or takes longer than `timeout`.
    static func run(_ argv: [String], path: String, timeout: Double) -> String? {
        var env = ProcessInfo.processInfo.environment; env["PATH"] = path; env["NO_COLOR"] = "1"
        guard let r = try? Subprocess.run(argv, cwd: NSHomeDirectory(), env: env, timeLimit: timeout), r.status == 0, !r.timedOut, !r.truncated else { return nil }
        return String(decoding: r.stdout + r.stderr, as: UTF8.self)
    }

    /// "claude 2.1.3 (Claude Code)" → "2.1.3".
    static func semver(_ s: String) -> String? { s.firstMatch(of: /\d+\.\d+\.\d+/).map { String($0.output) } }

    /// The last `bytes` (0 to 16 MB) it printed.
    func liveSessionOrLog(_ id: String, bytes: Int) throws -> Data {
        let bytes = max(0, min(bytes, 16 << 20))
        if let ls = existing(id) { return ls.tail(bytes) }
        // Only a session Kelp has: the id names a file, and "../../x" would name any .log the user can read.
        guard (try? store.session(id)) != nil, let d = Data(tailOf: root.appendingPathComponent("history/\(id).log"), bytes: bytes) else {
            throw RPCError.invalidParams("no history for \(id)")
        }
        return d
    }

    /// Transcript of a session written to ~/.kelp/handoff/<id>.md for the next agent to read. Claude Code's own
    /// conversation (what was asked and answered) when there is one; otherwise the terminal's text.
    func handoffFile(_ s: Session, full: Bool) throws -> URL {
        let limit = full ? 400_000 : 40_000
        let body: String
        if let t = existing(s.id).flatMap(agentUsage.transcript(of:)), let talk = AgentUsage.conversation(transcript: t, limit: limit), !talk.isEmpty {
            body = talk
        } else {
            let d = try liveSessionOrLog(s.id, bytes: limit)
            // swiftlint:disable:next optional_data_string_conversion
            body = "```\n" + StatusDetector.stripANSI(String(decoding: d, as: UTF8.self)) + "\n```"   // lossy on purpose, see session.context
        }
        let dir = root.appendingPathComponent("handoff"); try Paths.ensure(dir)
        let u = dir.appendingPathComponent("\(s.id).md")
        try ("# Previous session (\(s.agent ?? "agent"), \(s.cwd))\n\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    // MARK: keep awake

    /// keepAwake: "always" | "agents" (only while an agent is working) | "off".
    /// "always" is Caffeine: the screen stays on too. Agents only need the Mac itself, so the screen may still sleep and lock.
    func applyKeepAwake() {
        let mode = settings["power.keepAwake"]?.string ?? "agents"
        let working = live.all.contains { $0.snapshot.status == .working && $0.snapshot.agent != "shell" }
        let want = mode == "always" ? kIOPMAssertPreventUserIdleDisplaySleep
            : mode == "agents" && working ? kIOPMAssertPreventUserIdleSystemSleep : nil
        sleepAssertion.withLock { held in   // the ticker and a settings change at once: one assertion
            guard held.type != want else { return }
            if held.id != 0 { IOPMAssertionRelease(held.id); held = (0, nil) }
            guard let want else { return }
            var id: IOPMAssertionID = 0
            let name = mode == "always" ? "Keep Mac Awake is on in Kelp" : "Kelp agents are working"
            if IOPMAssertionCreateWithName(want as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id) == kIOReturnSuccess {
                held = (id, want)
            }
        }
    }
}

extension SessionRename: Handled {
    func handle(_ d: Daemon) throws -> Done {
        // Under its wake lock: a paused record read here and saved back must not land over a wake that started meanwhile.
        try d.wakeLocks.withLock(id) {
            if let ls = d.existing(id) { _ = ls.update { $0.title = title; $0.titleManual = !title.isEmpty }; d.publish(ls) }
            else if var s = try d.store.session(id) { s.title = title; s.titleManual = !title.isEmpty; d.publish(s) }
        }
        return Done()
    }
}

extension Daemon {
    /// argv without `--session-id <id>`: two sessions can't share an id (Claude Code refuses one already used).
    static func withoutSessionId(_ argv: [String], flag: String?) -> [String] {
        guard let flag, let i = argv.firstIndex(of: flag) else { return argv }
        var a = argv; a.removeSubrange(i...min(i + 1, a.count - 1)); return a
    }
}
