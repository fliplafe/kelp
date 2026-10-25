import Core

/// Plan limits crossing 80 % or 95 %: one alert per level, until the limit falls back under 70 % (its window reset).
struct LimitAlerts {
    struct Alert: Equatable { var agent: String, kind: String, percent: Double, level: Int, resets: String? }
    static let levels = [80, 95]

    private var told: [String: Int] = [:]   // "agent|kind" → highest level already announced
    private var seeded = false

    /// Every limit the agents report now, as the sidebar's rings show them.
    static func readings(_ u: UsageGet.Result) -> [(agent: String, limit: UsageGet.Limit)] {
        var out = (u.plans ?? [:]).flatMap { a, ls in ls.map { (a, $0) } }.filter { $0.0 != "claude" }
        out += (u.plans?["claude"] ?? u.claudeLimits ?? []).map { ("claude", $0) }
        if let x = u.codex.first {
            if let p = x.primaryUsedPercent { out.append(("codex", .init(kind: "session", percent: p, resets: nil))) }
            if let p = x.secondaryUsedPercent { out.append(("codex", .init(kind: "week", percent: p, resets: nil))) }
        }
        return out.map { (agent: $0.0, limit: $0.1) }
    }

    /// The first reading only sets the baseline: what was already full when Kelp opened isn't news.
    mutating func update(_ u: UsageGet.Result) -> [Alert] {
        var alerts: [Alert] = []
        for (agent, l) in Self.readings(u) {
            let key = agent + "|" + l.kind
            let level = Self.levels.last { l.percent >= Double($0) } ?? 0
            if l.percent < 70 { told[key] = nil }
            guard level > (told[key] ?? 0) else { continue }
            told[key] = level
            if seeded { alerts.append(Alert(agent: agent, kind: l.kind, percent: l.percent, level: level, resets: l.resets)) }
        }
        seeded = true
        return alerts
    }
}
