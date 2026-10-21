import Foundation
import IOKit.pwr_mgt
import Core
import GitKit
import Agents

/// RPCs that chain several steps or wait on other processes.
extension Daemon {

    /// What a short command prints (stdout and stderr), or nil if it fails or takes longer than `timeout`.
    /// The pipe is read while the command runs (`ps` on a busy Mac prints more than a pipe holds), and the exit is watched
    /// from before it starts (one that exits at once isn't missed).
    static func run(_ argv: [String], path: String, timeout: Double) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: argv[0]); p.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment; env["PATH"] = path; env["NO_COLOR"] = "1"; p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0), read = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        guard (try? p.run()) != nil else { return nil }
        let data = Locked(Data())
        Thread.detachNewThread { let d = out.fileHandleForReading.readDataToEndOfFile(); data.withLock { $0 = d }; read.signal() }
        // A child that keeps the pipe open past the exit (a daemon it started) doesn't hold this up either.
        guard exited.wait(timeout: .now() + timeout) == .success, read.wait(timeout: .now() + 1) == .success else { p.terminate(); return nil }
        return p.terminationStatus == 0 ? String(decoding: data.current, as: UTF8.self) : nil
    }

    /// "claude 2.1.3 (Claude Code)" → "2.1.3".
    static func semver(_ s: String) -> String? { s.firstMatch(of: /\d+\.\d+\.\d+/).map { String($0.output) } }

    /// The last `bytes` (0 to 16 MB) it printed.
    func liveSessionOrLog(_ id: String, bytes: Int) throws -> Data {
        let bytes = max(0, min(bytes, 16 << 20))
        if let ls = existing(id) { return ls.tail(bytes) }
        // Only a session Kelp has: the id names a file, and "../../x" would name any .log the user can read.
        guard (try? store.session(id)) != nil, let h = try? FileHandle(forReadingFrom: root.appendingPathComponent("history/\(id).log")) else {
            throw RPCError.invalidParams("no history for \(id)")
        }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? h.readToEnd()) ?? Data()
    }

    /// Transcript of a session written to ~/.kelp/handoff/<id>.md for the next agent to read. Claude Code's own
    /// conversation (what was asked and answered) when there is one; otherwise the terminal's text.
    func handoffFile(_ s: Session, full: Bool) throws -> URL {
        let limit = full ? 400_000 : 40_000
        let body: String
        if let t = existing(s.id).flatMap(transcript(of:)), let talk = Self.conversation(transcript: t, limit: limit), !talk.isEmpty {
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

    /// "## You / ## Claude" turns from a Claude Code transcript, newest kept when it's longer than `limit`.
    static func conversation(transcript url: URL, limit: Int) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var turns: [String] = []
        for line in data.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let type = o["type"] as? String,
                  type == "user" || type == "assistant", let msg = o["message"] as? [String: Any] else { continue }
            let text: String
            if let s = msg["content"] as? String { text = s }
            else { text = ((msg["content"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n") }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.hasPrefix("<") else { continue }   // tool results and system notes aren't the conversation
            turns.append("## \(type == "user" ? "You" : "Agent")\n\n\(t)")
        }
        var out = turns.joined(separator: "\n\n")
        if out.count > limit { out = "…\n\n" + String(out.suffix(limit)) }
        return out
    }

    // MARK: keep awake

    /// keepAwake: "always" | "agents" (only while an agent is working) | "off".
    func applyKeepAwake() {
        let mode = settings["power.keepAwake"]?.string ?? "agents"
        let working = live.all.contains { $0.snapshot.status == .working && $0.snapshot.agent != "shell" }
        let want = mode == "always" || (mode == "agents" && working)
        sleepAssertion.withLock { held in   // the ticker and a settings change at once: one assertion
            if want, held == 0 {
                var id: IOPMAssertionID = 0
                if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Kelp agents are working" as CFString, &id) == kIOReturnSuccess { held = id }
            } else if !want, held != 0 {
                IOPMAssertionRelease(held); held = 0
            }
        }
    }
}

extension SessionRename: Handled {
    func handle(_ d: Daemon) throws -> Done {
        // Under wakeLock: a paused record read here and saved back must not land over a wake that started meanwhile.
        try d.wakeLock.withLock {
            if let ls = d.existing(id) { d.publish(ls.update { $0.title = title; $0.titleManual = !title.isEmpty }) }
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
