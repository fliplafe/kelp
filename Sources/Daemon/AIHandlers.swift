import Foundation
import IOKit.pwr_mgt
import Core
import GitKit
import Agents

/// RPCs that chain several steps or wait on other processes.
extension Daemon {
    /// git, transcripts and the worktree they make all block: run through `offload` (see `handle`).
    func handleAgents(_ method: String, _ p: JSONValue, conn: Int) throws -> JSONValue? {
        switch method {
        case "session.annotate":   // summary from the UI (the agent's own last reply), optionally a better status guess
            guard let ls = existing(try p.req("id")) else { return .null }
            if let sum = p["summary"]?.string { publish(ls.update { $0.summary = sum }) }
            if let st = p["status"]?.string.flatMap(AgentStatus.init(rawValue:)) { ls.overrideStatus(st) }
            return .null

        case "session.context":    // bounded transcript for "Copy Context"
            let d = try liveSessionOrLog(p.req("id"), bytes: p["bytes"]?.int ?? 24_000)
            // Lossy on purpose: a byte window can cut a UTF-8 sequence, and the rest of the text still matters.
            // swiftlint:disable:next optional_data_string_conversion
            return .string(StatusDetector.stripANSI(String(decoding: d, as: UTF8.self)))

        case "session.restart":    // same command, same directory; resumes the conversation when the agent supports it
            guard let old = try store.session(p.req("id")) else { throw RPCError.invalidParams("no session") }
            existing(old.id)?.pty.kill()   // if the new one can't start, this one still ends as Ended
            let m = try manifest(old.agent == "custom" || old.agent == "shell" ? old.agent : old.agent, command: nil, fallbackArgv: old.argv)
            var o = Launch(p); o.title = old.titleManual ? old.title : nil
            o.argv = p["resume"]?.bool != false ? resumeArgv(old, m) : old.argv
            let s = try spawn(cwd: old.cwd, manifest: m, worktreeId: old.worktreeId, o)
            discard(old)   // its exit, still to come, doesn't save it again
            return try .from(s)

        case "session.handoff":   // a new agent in the same workspace, briefed with this one's transcript
            guard let old = try store.session(p.req("id")) else { throw RPCError.invalidParams("no session") }
            let transcript = try handoffFile(old, full: p["full"]?.bool == true)
            let task = p["prompt"]?.string ?? "Continue the task where the previous agent left off."
            var o = Launch(p)
            o.prompt = "Read \(transcript.path) — the transcript of the previous agent session in this project. \(task)"
            o.draft = p["draft"]?.bool == true
            o.title = (old.title.isEmpty ? (old.agent ?? "agent") : old.title) + " (handoff)"
            let s = try spawn(cwd: old.cwd, manifest: manifest(p["agent"]?.string ?? old.agent, command: nil), worktreeId: old.worktreeId, o)
            return try .from(s)

        case "recipe.render":   // agent prompt for an action, with the repo's override if any
            let w = try cwd(forWorktree: p.req("id"))
            let cfg = RepoConfig.load(repoPath: try store.repo(w.repoId)?.path ?? w.path)
            var vars: [String: String] = ["branch": w.branch, "base": try store.repo(w.repoId)?.baseBranch ?? "main"]
            if case .object(let o) = p["vars"] ?? .null { for (k, v) in o { vars[k] = v.string ?? "" } }
            if vars["stagedPatch"] == nil { vars["stagedPatch"] = String(((try? Git.run(["diff", "--cached", "--stat"], cwd: w.path)) ?? "").prefix(4000)) }
            return .string(Recipes.render(try p.req("name"), config: cfg, vars: vars))

        default: return nil
        }
    }

    /// Waits on several processes side by side, each through `offload`.
    func handleAsync(_ method: String, _ p: JSONValue, conn: Int) async throws -> JSONValue? {
        switch method {
        case "agents.versions":   // [{id, version?, latest?}] for the agents on this Mac; latest from npm where they publish there
            let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
            let rows: [JSONValue] = await withTaskGroup(of: JSONValue?.self) { g in
                for m in manifests {
                    g.addTask { [self] in
                        try? await offload { [self] () -> JSONValue? in
                            let path = childPath   // the login shell's PATH: the first read waits for the shell
                            guard let exe = try? LoginPath.resolve(m.command) else { return nil }
                            let v = Self.run([exe, "--version"], path: path, timeout: 4).flatMap(Self.semver)
                            let npm = try? LoginPath.resolve("npm")
                            let latest = m.npm.flatMap { pkg in npm.flatMap { Self.run([$0, "view", pkg, "version"], path: path, timeout: 8) } }.flatMap(Self.semver)
                            return .obj(["id": .string(m.id), "version": v.map { .string($0) } ?? .null, "latest": latest.map { .string($0) } ?? .null])
                        }
                    }
                }
                var out: [JSONValue] = []
                for await r in g { if let r { out.append(r) } }
                return out
            }
            return .array(rows)
        default: return nil
        }
    }

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
        nonisolated(unsafe) var data = Data()
        Thread.detachNewThread { data = out.fileHandleForReading.readDataToEndOfFile(); read.signal() }
        // A child that keeps the pipe open past the exit (a daemon it started) doesn't hold this up either.
        guard exited.wait(timeout: .now() + timeout) == .success, read.wait(timeout: .now() + 1) == .success else { p.terminate(); return nil }
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// "claude 2.1.3 (Claude Code)" → "2.1.3".
    static func semver(_ s: String) -> String? { s.firstMatch(of: /\d+\.\d+\.\d+/).map { String($0.output) } }

    /// The last `bytes` (0 to 16 MB) it printed.
    func liveSessionOrLog(_ id: String, bytes: Int) throws -> Data {
        let bytes = max(0, min(bytes, 16 << 20))
        if let ls = existing(id) { return ls.tail(bytes) }
        let u = root.appendingPathComponent("history/\(id).log")
        guard let h = try? FileHandle(forReadingFrom: u) else { throw RPCError.invalidParams("no history for \(id)") }
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
        lock.lock(); let working = live.values.contains { $0.snapshot.status == .working && $0.snapshot.agent != "shell" }; lock.unlock()
        let want = mode == "always" || (mode == "agents" && working)
        keepAwakeLock.lock(); defer { keepAwakeLock.unlock() }   // the ticker and a settings change at once: one assertion
        if want, sleepAssertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Kelp agents are working" as CFString, &id) == kIOReturnSuccess { sleepAssertion = id }
        } else if !want, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0
        }
    }
}

extension SessionRename: Handled {
    func handle(_ d: Daemon) throws -> Done {
        if let ls = d.existing(id) { d.publish(ls.update { $0.title = title; $0.titleManual = !title.isEmpty }) }
        else if var s = try d.store.session(id) { s.title = title; s.titleManual = !title.isEmpty; d.publish(s) }
        return Done()
    }
}
