import Foundation
import IOKit.pwr_mgt
import Core
import GitKit
import Agents

/// Async RPCs: things that chain several steps or wait on other processes.
extension Daemon {
    func handleAsync(_ method: String, _ p: JSONValue, conn: Int) async throws -> JSONValue? {
        switch method {
        case "task.create":   // workspace: branch (named from the task or name) + worktree + agent that receives the task
            guard let r = try store.repo(p.req("repoId")) else { throw RPCError.invalidParams("no repo") }
            let agent = try manifest(p["agent"]?.string ?? "claude", command: nil)
            _ = try LoginPath.resolve(agent.command)   // fail before making a branch and checkout for nothing
            let prompt = (p["prompt"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (p["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var branch = p["branch"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? (name.isEmpty ? Naming.slug(prompt) : Naming.slug(name, words: 8))
            if branch.isEmpty { branch = "workspace-\(Int(Date().timeIntervalSince1970) % 100000)" }
            if let prefix = p["branchPrefix"]?.string, !prefix.isEmpty, !branch.hasPrefix(prefix) { branch = prefix + branch }
            var unique = branch, n = 2
            while Git.branchExists(r.path, unique) { unique = "\(branch)-\(n)"; n += 1 }
            let title = name.isEmpty ? (prompt.isEmpty ? "" : Naming.title(prompt)) : name
            let w = try await handle("worktree.create", .obj(["repoId": .string(r.id), "branch": .string(unique), "base": p["base"] ?? .null,
                                                              "note": .string(title), "tabs": false]), conn: conn)
            var o = Launch(p); o.prompt = prompt.isEmpty ? nil : prompt; o.title = title.isEmpty ? nil : title
            let s = try spawn(cwd: try w.req("path"), manifest: agent, worktreeId: try w.req("id"), o)
            return .obj(["worktree": w, "session": try .from(s)])

        case "session.rename":
            let t = try p.req("title")
            if let ls = existing(try p.req("id")) { publish(ls.update { $0.title = t; $0.titleManual = !t.isEmpty }) }
            else if var s = try store.session(p.req("id")) { s.title = t; s.titleManual = !t.isEmpty; publish(s) }
            return .null

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
            existing(old.id)?.pty.kill()
            let m = try manifest(old.agent == "custom" || old.agent == "shell" ? old.agent : old.agent, command: nil, fallbackArgv: old.argv)
            var o = Launch(p); o.title = old.titleManual ? old.title : nil
            o.argv = p["resume"]?.bool != false ? resumeArgv(old, m) : old.argv
            let s = try spawn(cwd: old.cwd, manifest: m, worktreeId: old.worktreeId, o)
            try store.delete(old)
            return try .from(s)

        case "session.fork", "session.handoff":
            // fork: new worktree from this branch; handoff: same worktree. Both seed a new agent with the transcript.
            guard let old = try store.session(p.req("id")) else { throw RPCError.invalidParams("no session") }
            let transcript = try handoffFile(old, full: p["full"]?.bool == true)
            var cwdPath = old.cwd, wid = old.worktreeId
            if method == "session.fork", let w = try store.worktree(old.worktreeId ?? "") {
                var b = w.branch + "-fork", n = 2
                guard let r = try store.repo(w.repoId) else { throw RPCError.invalidParams("no repo") }
                while Git.branchExists(r.path, b) { b = "\(w.branch)-fork-\(n)"; n += 1 }
                let nw = try await handle("worktree.create", .obj(["repoId": .string(r.id), "branch": .string(b), "base": .string(w.branch), "note": .string("fork of \(w.branch)"), "tabs": false]), conn: conn)
                cwdPath = try nw.req("path"); wid = try nw.req("id")
            }
            let task = p["prompt"]?.string ?? "Continue the task where the previous agent left off."
            var o = Launch(p)
            o.prompt = "Read \(transcript.path) — the transcript of the previous agent session in this project. \(task)"
            o.draft = p["draft"]?.bool == true
            o.title = (old.title.isEmpty ? (old.agent ?? "agent") : old.title) + (method == "session.fork" ? " (fork)" : " (handoff)")
            let s = try spawn(cwd: cwdPath, manifest: manifest(p["agent"]?.string ?? old.agent, command: nil), worktreeId: wid, o)
            return try .from(s)

        case "agents.versions":   // [{id, version?, latest?}] for the agents on this Mac; latest from npm where they publish there
            let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
            let path = childPath
            let rows: [JSONValue] = await withTaskGroup(of: JSONValue?.self) { g in
                for m in manifests {
                    g.addTask {
                        guard let exe = try? LoginPath.resolve(m.command) else { return nil }
                        let v = Self.run([exe, "--version"], path: path, timeout: 4).flatMap(Self.semver)
                        let npm = try? LoginPath.resolve("npm")
                        let latest = m.npm.flatMap { pkg in npm.flatMap { Self.run([$0, "view", pkg, "version"], path: path, timeout: 8) } }.flatMap(Self.semver)
                        return .obj(["id": .string(m.id), "version": v.map { .string($0) } ?? .null, "latest": latest.map { .string($0) } ?? .null])
                    }
                }
                var out: [JSONValue] = []
                for await r in g { if let r { out.append(r) } }
                return out
            }
            return .array(rows)

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

    /// What a short command prints (stdout and stderr), or nil if it fails or takes longer than `timeout`.
    static func run(_ argv: [String], path: String, timeout: Double) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: argv[0]); p.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment; env["PATH"] = path; env["NO_COLOR"] = "1"; p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return p.terminationStatus == 0 ? text : nil
    }

    /// "claude 2.1.3 (Claude Code)" → "2.1.3".
    static func semver(_ s: String) -> String? { s.firstMatch(of: /\d+\.\d+\.\d+/).map { String($0.output) } }

    func liveSessionOrLog(_ id: String, bytes: Int) throws -> Data {
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
        if want, sleepAssertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Kelp agents are working" as CFString, &id) == kIOReturnSuccess { sleepAssertion = id }
        } else if !want, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0
        }
    }
}
