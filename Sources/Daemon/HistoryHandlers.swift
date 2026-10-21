import Foundation
import Core
import Agents
import AgentData
import os

/// The transcripts history.list read last, by the folders read. Its search field asks on every keystroke, and each read
/// parses the head and tail of every conversation on disk: a search reuses the list read when the window opened (or a
/// minute ago). Keyed by folders, not one slot: daemons in one process (tests) each find their own.
private let historyRead = OSAllocatedUnfairLock<[[URL]: (at: Date, list: [AgentSessionInfo])]>(initialState: [:])

/// Session history across Claude/Codex (and account profiles), usage and rate limits.
extension Daemon {
    /// Default roots plus each account profile's config dir.
    func agentRoots() -> (claude: [URL], codex: [URL]) {
        var c = [agentHomes.claude], x = [agentHomes.codex]
        for p in settings["accounts.profiles"]?.array ?? [] {
            guard let d = p["dir"]?.string else { continue }
            if p["agent"]?.string == "claude" { c.append(URL(fileURLWithPath: d).appendingPathComponent("projects")) }
            if p["agent"]?.string == "codex" { x.append(URL(fileURLWithPath: d).appendingPathComponent("sessions")) }
        }
        return (c, x)
    }

    /// Where a Claude Code session writes its conversation: what its hooks said, else the id Kelp started or resumed it
    /// with (a woken or restarted session has sent no hook yet, but its conversation is already there).
    func transcript(of ls: LiveSession) -> URL? {
        if let t = ls.transcriptPath { return URL(fileURLWithPath: t) }
        let s = ls.snapshot, a = s.argv
        guard s.agent == "claude", let i = a.lastIndex(where: { $0 == "--session-id" || $0 == "--resume" }), i + 1 < a.count else { return nil }
        return agentRoots().claude.map { ClaudeHistory.folder(cwd: s.cwd, root: $0).appendingPathComponent(a[i + 1] + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Claude Code's window for `model`. Transcripts don't name it, so a model seen past 200k tokens here (in the newest
    /// transcripts, then in any reading) has 1M and the rest 200k.
    /// Limit: a 1M model that never went past 200k on this Mac reads as 200k until it does.
    func contextWindow(model: String, peak: Int) -> Int {
        var long = lock.withLock { longContextModels } ?? Self.longContextModels(in: agentRoots().claude)
        if peak > 200_000 { long.insert(model) }
        lock.withLock { longContextModels = long }
        return long.contains(model) ? 1_000_000 : 200_000
    }

    /// Models past 200k tokens at the end of the `count` newest transcripts.
    static func longContextModels(in roots: [URL], count: Int = 20) -> Set<String> {
        let key = URLResourceKey.contentModificationDateKey
        let files = roots.flatMap { (FileManager.default.enumerator(at: $0, includingPropertiesForKeys: [key])?.allObjects as? [URL]) ?? [] }
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast) }
        let newest = files.sorted { $0.1 > $1.1 }.prefix(count).map(\.0)
        return Set(newest.compactMap { contextUsage(transcript: $0) }.filter { $0.peak > 200_000 }.map(\.model))
    }

    static func json(_ b: ClaudeUsage.Block) -> JSONValue {
        .obj(["start": .double(b.start.timeIntervalSince1970), "end": .double(b.end.timeIntervalSince1970),
              "input": .int(b.tokens.input), "output": .int(b.tokens.output), "cacheWrite": .int(b.tokens.cacheWrite), "cacheRead": .int(b.tokens.cacheRead),
              "cost": .double(b.estimatedCostUSD), "models": .array(b.models.map { .string($0) })])
    }

    /// Claude's own percentages from the last 12 hours (they reset; older readings mislead).
    func withLimits(_ v: JSONValue) -> JSONValue {
        guard case .object(var o) = v else { return v }
        refreshPlansIfStale()
        let plans = lock.withLock { self.plans }
        o["plans"] = .object(plans.filter { !$0.value.readings.isEmpty }.mapValues { s in
            .array(s.readings.map { .obj(["kind": .string($0.kind), "percent": .double($0.percent), "resets": $0.resets.map { .string($0) } ?? .null]) })
        })
        // When each plan was last read: an old reading is shown as old, not as today's.
        o["plansReadAt"] = .object(plans.compactMapValues { s in s.readAt.map { .double($0.timeIntervalSince1970) } })
        let fresh = lock.withLock { claudeLimits.values.filter { Date().timeIntervalSince($0.at) < 12 * 3600 } }
        o["claudeLimits"] = .array(fresh.sorted { $0.reading.kind < $1.reading.kind }.map { x in
            .obj(["kind": .string(x.reading.kind), "percent": .double(x.reading.percent), "resets": x.reading.resets.map { .string($0) } ?? .null,
                  "observedAt": .double(x.at.timeIntervalSince1970)])
        })
        return .object(o)
    }
}

/// Per account: Claude 5h block / today / week, Codex limits.
extension UsageGet: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        // Limit: one cached answer for 60 s (a scan reads GBs of transcripts); per-file incremental parsing if it gets slow
        let cached = d.lock.withLock { d.usageCache }
        if let c = cached, Date().timeIntervalSince(c.at) < 60, force != true { return d.withLimits(c.value) }
        let roots = d.agentRoots()
        var claude: [JSONValue] = [], codex: [JSONValue] = []
        let names = ["Default"] + (d.settings["accounts.profiles"]?.array ?? []).compactMap { $0["name"]?.string }
        for (i, r) in roots.claude.enumerated() where FileManager.default.fileExists(atPath: r.path) {
            // Today, the week and the 5-hour block from the index (read incrementally).
            let cal = Calendar.current, today = cal.startOfDay(for: Date()), now = Date()
            let weekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
            let rows = d.usageIndex.rows(roots: [r], since: weekStart)
            var o: [String: JSONValue] = ["account": .string(i == 0 ? "Default" : names[min(i, names.count - 1)]),
                                          "today": Daemon.json(UsageIndex.block(rows, from: today, to: now)),
                                          "week": Daemon.json(UsageIndex.block(rows, from: weekStart, to: now))]
            if let b = d.usageIndex.currentBlock(roots: [r], now: now) { o["block"] = Daemon.json(b) }
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
        d.lock.withLock { d.usageCache = (Date(), v) }
        return d.withLimits(v)
    }
}

/// What Claude Code used, by day / model / project, priced as the API would.
extension UsageReport: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        let days = max(1, min(90, days ?? 30))
        let cal = Calendar.current, since = cal.date(byAdding: .day, value: 1 - days, to: cal.startOfDay(for: Date())) ?? Date()
        let rows = d.usageIndex.rows(roots: d.agentRoots().claude.filter { FileManager.default.fileExists(atPath: $0.path) }, since: since)
        let repos = (try? d.store.repos()) ?? []
        func project(_ cwd: String) -> String {
            repos.first { cwd == $0.path || cwd.hasPrefix($0.path + "/") }?.name ?? (cwd.isEmpty ? "Other" : (cwd as NSString).lastPathComponent)
        }
        func group(_ key: (UsageIndex.Row) -> String) -> [JSONValue] {
            Dictionary(grouping: rows, by: key).map { k, rs in (k, rs.reduce(0) { $0 + $1.tally.cost }, rs.reduce(0) { $0 + $1.tally.tokens.total }) }
                .sorted { $0.1 > $1.1 }.map { .obj(["name": .string($0.0), "cost": .double($0.1), "tokens": .int($0.2)]) }
        }
        return .obj(["days": .array(group(\.day)), "models": .array(group(\.model)), "projects": .array(group { project($0.cwd) }),
                     "since": .double(since.timeIntervalSince1970)])
    }
}

extension HistoryList: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        let roots = d.agentRoots(), key = roots.claude + roots.codex
        var all: [AgentSessionInfo]
        if query?.isEmpty == false, let r = historyRead.withLock({ $0[key] }), Date().timeIntervalSince(r.at) < 60 {
            all = r.list
        } else {
            all = roots.claude.flatMap { ClaudeHistory.sessions(root: $0) } + roots.codex.flatMap { CodexHistory.sessions(root: $0) }
            all.sort { $0.updated > $1.updated }
            historyRead.withLock { [all] in $0[key] = (Date(), all) }
        }
        if let q = query, !q.isEmpty {
            all = fullText == true ? History.fullTextSearch(query: q, in: all, limit: 100) : History.search(all, query: q)
        }
        if let cwd = cwd { all = all.filter { $0.cwd == cwd } }
        return try .from(Array(all.prefix(max(0, limit ?? 400))))
    }
}
