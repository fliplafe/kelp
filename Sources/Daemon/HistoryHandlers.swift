import Foundation
import Core
import Agents
import AgentData
import os

/// Per account: Claude 5h block / today / week, Codex limits.
extension UsageGet: Handled {
    func handle(_ usage: AgentUsage) throws -> Result {
        // Limit: one cached answer for 60 s (a scan reads GBs of transcripts); per-file incremental parsing if it gets slow
        let cached = usage.usageCache.withLock { $0 }
        if let c = cached, Date().timeIntervalSince(c.at) < 60, force != true { return usage.withLimits(c.value) }
        let roots = usage.agentRoots()
        var claude: [Claude] = [], codex: [Codex] = []
        let names = ["Default"] + (usage.settings["accounts.profiles"]?.array ?? []).compactMap { $0["name"]?.string }
        for (i, r) in roots.claude.enumerated() where FileManager.default.fileExists(atPath: r.path) {
            // Today, the week and the 5-hour block from the index (read incrementally).
            let cal = Calendar.current, today = cal.startOfDay(for: Date()), now = Date()
            let weekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
            let rows = usage.usageIndex.rows(roots: [r], since: weekStart)
            claude.append(Claude(account: i == 0 ? "Default" : names[min(i, names.count - 1)],
                                 today: AgentUsage.block(UsageIndex.block(rows, from: today, to: now)),
                                 week: AgentUsage.block(UsageIndex.block(rows, from: weekStart, to: now)),
                                 block: usage.usageIndex.currentBlock(roots: [r], now: now).map(AgentUsage.block)))
        }
        let live = usage.codexLive.withLock { $0.limits }
        for (i, r) in roots.codex.enumerated() where i == 0 || FileManager.default.fileExists(atPath: r.path) {
            // The default account's (the first) is also asked of its app server (UsageProbe): the newer reading wins.
            let l = [CodexUsage.latest(root: r), i == 0 ? live : nil].compactMap { $0 }.max { $0.observedAt < $1.observedAt }
            if let l { codex.append(AgentUsage.codex(l)) }
        }
        let v = Result(claude: claude, codex: codex)
        usage.usageCache.withLock { $0 = (Date(), v) }
        return usage.withLimits(v)
    }
}

/// What Claude Code used, by day / model / project, priced as the API would.
extension UsageReport: Handled {
    func handle(_ usage: AgentUsage) throws -> Result {
        let days = max(1, min(90, days ?? 30))
        let cal = Calendar.current, since = cal.date(byAdding: .day, value: 1 - days, to: cal.startOfDay(for: Date())) ?? Date()
        let rows = usage.usageIndex.rows(roots: usage.agentRoots().claude.filter { FileManager.default.fileExists(atPath: $0.path) }, since: since)
        let repos = (try? usage.store.repos()) ?? []
        func project(_ cwd: String) -> String {
            repos.first { cwd == $0.path || cwd.hasPrefix($0.path + "/") }?.name ?? (cwd.isEmpty ? "Other" : (cwd as NSString).lastPathComponent)
        }
        func group(_ key: (UsageIndex.Row) -> String) -> [Group] {
            Dictionary(grouping: rows, by: key).map { k, rs in Group(name: k, cost: rs.reduce(0) { $0 + $1.tally.cost }, tokens: rs.reduce(0) { $0 + $1.tally.tokens.total }) }
                .sorted { $0.cost > $1.cost }
        }
        return Result(days: group(\.day), models: group(\.model), projects: group { project($0.cwd) }, since: since.timeIntervalSince1970)
    }
}

extension HistoryList: Handled {
    func handle(_ usage: AgentUsage) throws -> [AgentSessionInfo] {
        let roots = usage.agentRoots(), key = roots.claude + roots.codex
        var all: [AgentSessionInfo]
        if query?.isEmpty == false, let r = usage.historyRead.withLock({ $0[key] }), Date().timeIntervalSince(r.at) < 60 {
            all = r.list
        } else {
            all = roots.claude.flatMap { ClaudeHistory.sessions(root: $0) } + roots.codex.flatMap { CodexHistory.sessions(root: $0) }
            all.sort { $0.updated > $1.updated }
            usage.historyRead.withLock { [all] in $0[key] = (Date(), all) }
        }
        if let q = query, !q.isEmpty {
            all = fullText == true ? History.fullTextSearch(query: q, in: all, limit: 100) : History.search(all, query: q)
        }
        if let cwd = cwd { all = all.filter { $0.cwd == cwd } }
        return Array(all.prefix(max(0, limit ?? 400)))
    }
}
