import Foundation
import IOKit.pwr_mgt
import Core
import GitKit
import Agents
import LocalAI

/// Async RPCs: things that call the local model, or chain several steps.
extension Daemon {
    func handleAsync(_ method: String, _ p: JSONValue, conn: Int) async throws -> JSONValue? {
        switch method {
        case "task.create":   // workspace: branch (named from the task or name) + worktree + agent that receives the task
            guard let r = try store.repo(p.req("repoId")) else { throw RPCError.invalidParams("no repo") }
            let prompt = (p["prompt"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (p["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let naming = prompt.isEmpty || !name.isEmpty ? nil : await LocalAI.naming(for: prompt)
            var branch = p["branch"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? (name.isEmpty ? nil : Fallback.slug(name, words: 8))
                ?? naming?.branch ?? Fallback.slug(prompt)
            if branch.isEmpty { branch = "workspace-\(Int(Date().timeIntervalSince1970) % 100000)" }
            if let prefix = p["branchPrefix"]?.string, !prefix.isEmpty, !branch.hasPrefix(prefix) { branch = prefix + branch }
            var unique = branch, n = 2
            while Git.branchExists(r.path, unique) { unique = "\(branch)-\(n)"; n += 1 }
            let title = name.isEmpty ? naming?.title ?? (prompt.isEmpty ? "" : Fallback.title(prompt)) : name
            let w = try await handle("worktree.create", .obj(["repoId": .string(r.id), "branch": .string(unique), "base": p["base"] ?? .null,
                                                              "note": .string(title), "tabs": false]), conn: conn)
            var o = Launch(p); o.prompt = prompt.isEmpty ? nil : prompt; o.title = title.isEmpty ? nil : title
            let s = try spawn(cwd: try w.req("path"), manifest: manifest(p["agent"]?.string ?? "claude", command: nil), worktreeId: try w.req("id"), o)
            return .obj(["worktree": w, "session": try .from(s)])

        case "session.rename":
            let t = try p.req("title")
            if let ls = existing(try p.req("id")) { publish(ls.update { $0.title = t; $0.titleManual = !t.isEmpty }) }
            else if var s = try store.session(p.req("id")) { s.title = t; s.titleManual = !t.isEmpty; publish(s) }
            return .null

        case "session.annotate":   // local-model summary from the UI, optionally a better status guess
            guard let ls = existing(try p.req("id")) else { return .null }
            if let sum = p["summary"]?.string { publish(ls.update { $0.summary = sum }) }
            if let st = p["status"]?.string.flatMap(AgentStatus.init(rawValue:)) { ls.overrideStatus(st) }
            return .null

        case "session.context":    // bounded transcript for "Copy Context"
            let d = try liveSessionOrLog(p.req("id"), bytes: p["bytes"]?.int ?? 24_000)
            return .string(StatusDetector.stripANSI(String(decoding: d, as: UTF8.self)))

        case "session.restart":    // same command, same directory; resumes the conversation when the agent supports it
            guard let old = try store.session(p.req("id")) else { throw RPCError.invalidParams("no session") }
            existing(old.id)?.pty.kill()
            let m = try manifest(old.agent == "custom" || old.agent == "shell" ? old.agent : old.agent, command: nil, fallbackArgv: old.argv)
            var o = Launch(p); o.title = old.titleManual ? old.title : nil
            if p["resume"]?.bool != false, !m.resumeArgs.isEmpty, !old.argv.contains(where: m.resumeArgs.contains) { o.argv = old.argv + m.resumeArgs }
            else { o.argv = old.argv }
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
            o.title = (old.title.isEmpty ? (old.agent ?? "agent") : old.title) + (method == "session.fork" ? " (fork)" : " (handoff)")
            let s = try spawn(cwd: cwdPath, manifest: manifest(p["agent"]?.string ?? old.agent, command: nil), worktreeId: wid, o)
            return try .from(s)

        case "worktree.renameBranch":
            guard var w = try store.worktree(p.req("id")) else { throw RPCError.invalidParams("no worktree") }
            let new = try p.req("branch")
            try Git.renameBranch(w.path, from: w.branch, to: new)
            w.branch = new; try store.save(w); notify("event.changed", "worktree")
            return try .from(w)

        case "worktree.autoBranch":   // rename a placeholder branch from what the agent was asked to do
            guard let w = try store.worktree(p.req("id")) else { throw RPCError.invalidParams("no worktree") }
            guard let n = await LocalAI.naming(for: try p.req("prompt")) else { return .null }
            return try await handle("worktree.renameBranch", .obj(["id": .string(w.id), "branch": .string(n.branch)]), conn: conn)

        case "ai.commitMessage":
            let w = try cwd(forWorktree: p.req("id"))
            var diff = try Git.run(["diff", "--cached", "--no-color", "--stat", "-p"], cwd: w.path)
            if diff.isEmpty { diff = try Git.run(["diff", "HEAD", "--no-color", "--stat", "-p"], cwd: w.path) }
            guard !diff.isEmpty else { return .null }
            return (await LocalAI.commitMessage(diff: diff)).map { .string($0) } ?? .null

        case "ai.prDraft":
            let w = try cwd(forWorktree: p.req("id"))
            let base = try store.repo(w.repoId)?.baseBranch ?? "main"
            let commits = try Git.log(w.path, base: base).map(\.subject)
            let stat = (try? Git.run(["diff", "--stat", "\(base)...HEAD"], cwd: w.path)) ?? ""
            guard let d = await LocalAI.pullRequest(branch: w.branch, commits: commits, diffStat: stat, issue: p["issue"]?.string) else { return .null }
            return .obj(["title": .string(d.title), "body": .string(d.body)])

        case "recipe.render":   // agent prompt for an action, with the repo's override if any
            let w = try cwd(forWorktree: p.req("id"))
            let cfg = RepoConfig.load(repoPath: try store.repo(w.repoId)?.path ?? w.path)
            var vars: [String: String] = ["branch": w.branch, "base": try store.repo(w.repoId)?.baseBranch ?? "main"]
            if case .object(let o) = p["vars"] ?? .null { for (k, v) in o { vars[k] = v.string ?? "" } }
            if vars["stagedPatch"] == nil { vars["stagedPatch"] = String(((try? Git.run(["diff", "--cached", "--stat"], cwd: w.path)) ?? "").prefix(4000)) }
            return .string(Recipes.render(try p.req("name"), config: cfg, vars: vars))

        case "config.get": return .object(config)
        case "config.set":
            if case .object(let o) = p { for (k, v) in o { config[k] = v } }
            try saveConfig(); applyKeepAwake()
            return .object(config)

        default: return nil
        }
    }

    func liveSessionOrLog(_ id: String, bytes: Int) throws -> Data {
        if let ls = existing(id) { return ls.tail(bytes) }
        let u = root.appendingPathComponent("history/\(id).log")
        guard let h = try? FileHandle(forReadingFrom: u) else { throw RPCError.invalidParams("no history for \(id)") }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? h.readToEnd()) ?? Data()
    }

    /// Transcript of a session written to ~/.krill/handoff/<id>.md for the next agent to read.
    func handoffFile(_ s: Session, full: Bool) throws -> URL {
        let d = try liveSessionOrLog(s.id, bytes: full ? 400_000 : 40_000)
        let text = StatusDetector.stripANSI(String(decoding: d, as: UTF8.self))
        let dir = root.appendingPathComponent("handoff"); try Paths.ensure(dir)
        let u = dir.appendingPathComponent("\(s.id).md")
        try ("# Previous session (\(s.agent ?? "agent"), \(s.cwd))\n\n```\n" + text + "\n```\n").write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    // MARK: config + keep awake

    func saveConfig() throws {
        try JSONEncoder().encode(JSONValue.object(config)).write(to: root.appendingPathComponent("config.json"))
    }

    /// keepAwake: "always" | "agents" (only while an agent is working) | "off".
    func applyKeepAwake() {
        let mode = config["keepAwake"]?.string ?? "agents"
        lock.lock(); let working = live.values.contains { $0.snapshot.status == .working && $0.snapshot.agent != "shell" }; lock.unlock()
        let want = mode == "always" || (mode == "agents" && working)
        if want, sleepAssertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Krill agents are working" as CFString, &id) == kIOReturnSuccess { sleepAssertion = id }
        } else if !want, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0
        }
    }
}
