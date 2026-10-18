import Foundation
import Core
import Agents
import AgentData

/// Session history across Claude/Codex (and account profiles), usage and rate limits.
extension Daemon {
    /// Default roots plus each account profile's config dir.
    func agentRoots() -> (claude: [URL], codex: [URL]) {
        var c = [ClaudeHistory.defaultRoot], x = [CodexHistory.defaultRoot]
        for p in config["profiles"]?.array ?? [] {
            guard let d = p["dir"]?.string else { continue }
            if p["agent"]?.string == "claude" { c.append(URL(fileURLWithPath: d).appendingPathComponent("projects")) }
            if p["agent"]?.string == "codex" { x.append(URL(fileURLWithPath: d).appendingPathComponent("sessions")) }
        }
        return (c, x)
    }

    static func json(_ b: ClaudeUsage.Block) -> JSONValue {
        .obj(["start": .double(b.start.timeIntervalSince1970), "end": .double(b.end.timeIntervalSince1970),
              "input": .int(b.tokens.input), "output": .int(b.tokens.output), "cacheWrite": .int(b.tokens.cacheWrite), "cacheRead": .int(b.tokens.cacheRead),
              "cost": .double(b.estimatedCostUSD), "models": .array(b.models.map { .string($0) })])
    }

    func handleHistory(_ method: String, _ p: JSONValue) async throws -> JSONValue? {
        switch method {
        case "usage.get":   // per account: Claude 5h block / today / week, Codex limits
            // Limit: one cached answer for 60 s (a scan reads GBs of transcripts); per-file incremental parsing if it gets slow
            let cached = lock.withLock { usageCache }
            if let c = cached, Date().timeIntervalSince(c.at) < 60, p["force"]?.bool != true { return c.value }
            let roots = agentRoots()
            var claude: [JSONValue] = [], codex: [JSONValue] = []
            let names = ["Default"] + (config["profiles"]?.array ?? []).compactMap { $0["name"]?.string }
            for (i, r) in roots.claude.enumerated() where FileManager.default.fileExists(atPath: r.path) {
                let u = ClaudeUsage(root: r)
                var o: [String: JSONValue] = ["account": .string(i == 0 ? "Default" : names[min(i, names.count - 1)]),
                                              "today": Self.json(u.today()), "week": Self.json(u.last7Days())]
                if let b = u.currentBlock() { o["block"] = Self.json(b) }
                claude.append(.object(o))
            }
            for r in roots.codex where FileManager.default.fileExists(atPath: r.path) {
                guard let l = CodexUsage.latest(root: r) else { continue }
                var o: [String: JSONValue] = ["observedAt": .double(l.observedAt.timeIntervalSince1970)]
                if let v = l.primaryUsedPercent { o["primaryUsedPercent"] = .double(v) }
                if let v = l.primaryResetsAt { o["primaryResetsAt"] = .double(v.timeIntervalSince1970) }
                if let v = l.secondaryUsedPercent { o["secondaryUsedPercent"] = .double(v) }
                if let v = l.secondaryResetsAt { o["secondaryResetsAt"] = .double(v.timeIntervalSince1970) }
                codex.append(.object(o))
            }
            let v = JSONValue.obj(["claude": .array(claude), "codex": .array(codex)])
            lock.withLock { usageCache = (Date(), v) }
            return v

        case "history.list":
            let roots = agentRoots()
            var all = roots.claude.flatMap { ClaudeHistory.sessions(root: $0) } + roots.codex.flatMap { CodexHistory.sessions(root: $0) }
            all.sort { $0.updated > $1.updated }
            if let q = p["query"]?.string, !q.isEmpty {
                all = p["fullText"]?.bool == true ? History.fullTextSearch(query: q, in: all, limit: 100) : History.search(all, query: q)
            }
            if let cwd = p["cwd"]?.string { all = all.filter { $0.cwd == cwd } }
            return try .from(Array(all.prefix(p["limit"]?.int ?? 400)))

        case "history.resume":   // reopen a past conversation as a live session
            guard let s = try p["session"]?.decode(AgentSessionInfo.self) else { throw RPCError.invalidParams("session required") }
            var cwd = s.cwd, wid: String? = p["worktreeId"]?.string
            if let w = wid, let wt = try store.worktree(w) { cwd = wt.path } else {
                wid = try store.worktrees().first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == URL(fileURLWithPath: s.cwd).resolvingSymlinksInPath().path }?.id
            }
            guard FileManager.default.fileExists(atPath: cwd) else { throw RPCError.invalidParams("the session's folder no longer exists: \(cwd)") }
            let cmd = History.resumeCommand(for: s)
            var o = Launch(p); o.title = s.title.isEmpty ? "Resumed \(s.agent.rawValue)" : s.title
            var m = try manifest(s.agent.rawValue, command: nil)
            m.args += Array(cmd.dropFirst())
            return try .from(spawn(cwd: cwd, manifest: m, worktreeId: wid, o))
        default: return nil
        }
    }
}
