import Foundation

public struct TokenCounts: Codable, Sendable, Equatable {
    public var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
    public var total: Int { input + output + cacheWrite + cacheRead }
    public static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }
}

/// USD per million tokens.
public struct Pricing: Sendable, Equatable {
    public var input, output, cacheWrite, cacheRead: Double
    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
    public func cost(_ t: TokenCounts) -> Double {
        (Double(t.input) * input + Double(t.output) * output + Double(t.cacheWrite) * cacheWrite + Double(t.cacheRead) * cacheRead) / 1_000_000
    }

    /// ESTIMATE: list prices as of Oct 2026, hand-copied; they drift. Cache write = 5-minute TTL rate (1h writes cost more).
    /// First substring match wins, so specific ids precede their family fallback.
    public static let table: [(match: String, price: Pricing)] = [
        ("fable-5-1", .init(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 0.25)),
        ("mythos-5-1", .init(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 0.25)),
        ("fable", .init(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1)),
        ("mythos", .init(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1)),
        ("opus-5-5", .init(input: 4, output: 20, cacheWrite: 5, cacheRead: 0.2)),
        ("opus", .init(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)),
        ("sonnet-4", .init(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)),
        ("sonnet", .init(input: 2, output: 10, cacheWrite: 2.5, cacheRead: 0.2)),
        ("haiku-5", .init(input: 0.1, output: 0.5, cacheWrite: 0.125, cacheRead: 0.01)),
        ("haiku", .init(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1)),
        ("-mini", .init(input: 0.25, output: 2, cacheWrite: 0, cacheRead: 0.025)),
        ("gpt-5.2", .init(input: 1.75, output: 14, cacheWrite: 0, cacheRead: 0.175)),
        ("gpt-5", .init(input: 1.25, output: 10, cacheWrite: 0, cacheRead: 0.125)),
    ]

    public static func forModel(_ model: String) -> Pricing? {
        let m = model.lowercased()
        return table.first { m.contains($0.match) }?.price
    }

    /// 0 for unknown models.
    public static func cost(model: String, tokens: TokenCounts) -> Double { forModel(model)?.cost(tokens) ?? 0 }
}

/// Claude Code token usage from `message.usage` of assistant lines in transcripts.
public struct ClaudeUsage: Sendable {
    public struct Entry: Sendable, Equatable {
        public var timestamp: Date, model: String, tokens: TokenCounts
        public init(timestamp: Date, model: String, tokens: TokenCounts) { self.timestamp = timestamp; self.model = model; self.tokens = tokens }
    }

    /// Usage over `start..<end`. For a billing block `end` is when the 5-hour limit resets.
    public struct Block: Sendable, Equatable {
        public var start: Date, end: Date
        public var tokens: TokenCounts
        public var estimatedCostUSD: Double
        public var models: [String]
    }

    public static let blockLength: TimeInterval = 5 * 3600

    /// Sorted by timestamp, deduplicated.
    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries.sorted { $0.timestamp < $1.timestamp } }

    /// Reads every `*.jsonl` under `root` (subagents included) modified since `since`.
    // Limit: history before `since` is ignored, so a block chain with no 5h gap for 8+ days could start at a different hour than ccusage's.
    public init(root: URL = ClaudeHistory.defaultRoot, since: Date = Date().addingTimeInterval(-8 * 86400)) {
        self.init(entries: Self.load(root: root, since: since))
    }

    /// ccusage's algorithm: a block starts at its first message floored to the UTC hour and lasts 5h;
    /// the first message past that starts the next block (this also covers ccusage's "gap > 5h" rule).
    public func blocks(until now: Date = .distantFuture) -> [Block] {
        var out: [Block] = [], current: [Entry] = [], start = Date.distantPast
        for e in entries where e.timestamp <= now {
            if !current.isEmpty, e.timestamp.timeIntervalSince(start) <= Self.blockLength {
                current.append(e)
                continue
            }
            if !current.isEmpty { out.append(Self.summarize(start, start + Self.blockLength, current)) }
            start = Date(timeIntervalSince1970: (e.timestamp.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
            current = [e]
        }
        if !current.isEmpty { out.append(Self.summarize(start, start + Self.blockLength, current)) }
        return out
    }

    /// The block `now` falls in, or nil if the last one already reset.
    public func currentBlock(now: Date = Date()) -> Block? {
        guard let b = blocks(until: now).last, now < b.end else { return nil }
        return b
    }

    public func totals(from: Date, to: Date) -> Block {
        Self.summarize(from, to, entries.filter { $0.timestamp >= from && $0.timestamp < to })
    }

    /// The local calendar day containing `now`.
    public func today(now: Date = Date(), calendar: Calendar = .current) -> Block { days(1, now, calendar) }

    /// Today plus the six calendar days before it.
    public func last7Days(now: Date = Date(), calendar: Calendar = .current) -> Block { days(7, now, calendar) }

    func days(_ n: Int, _ now: Date, _ cal: Calendar) -> Block {
        let today = cal.startOfDay(for: now)
        func shift(_ d: Int) -> Date { cal.date(byAdding: .day, value: d, to: today) ?? today }
        return totals(from: shift(1 - n), to: shift(1))
    }

    static func summarize(_ start: Date, _ end: Date, _ es: [Entry]) -> Block {
        Block(start: start, end: end, tokens: es.reduce(TokenCounts()) { $0 + $1.tokens },
              estimatedCostUSD: es.reduce(0) { $0 + Pricing.cost(model: $1.model, tokens: $1.tokens) },
              models: Set(es.map(\.model)).sorted())
    }

    /// One entry per API response: Claude Code writes a line per content block (and resumed sessions copy history),
    /// so lines are deduplicated by `message.id` + `requestId`.
    static func load(root: URL, since: Date) -> [Entry] {
        let key: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(key))?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" && ((try? $0.resourceValues(forKeys: key).contentModificationDate) ?? .distantPast) >= since }
        let marker = Data("\"output_tokens\"".utf8)
        var seen = Set<String>(), out: [Entry] = []
        for f in files {
            guard let data = try? Data(contentsOf: f, options: .mappedIfSafe) else { continue }
            for line in JSONL.lines(data) where line.range(of: marker) != nil {
                guard let o = JSONL.object(line), o["type"] as? String == "assistant",
                      let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any],
                      let t = JSONL.date(o["timestamp"]), t >= since else { continue }
                let model = m["model"] as? String ?? "unknown"
                guard model != "<synthetic>" else { continue }
                let mid = m["id"] as? String, rid = o["requestId"] as? String
                if mid != nil || rid != nil, !seen.insert("\(mid ?? ""):\(rid ?? "")").inserted { continue }
                func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                out.append(Entry(timestamp: t, model: model, tokens: TokenCounts(
                    input: n("input_tokens"), output: n("output_tokens"),
                    cacheWrite: n("cache_creation_input_tokens"), cacheRead: n("cache_read_input_tokens"))))
            }
        }
        return out
    }
}

public struct CodexLimits: Sendable, Equatable {
    public var primaryUsedPercent: Double?, primaryResetsAt: Date?
    public var secondaryUsedPercent: Double?, secondaryResetsAt: Date?
    public var observedAt: Date
    public init(primaryUsedPercent: Double? = nil, primaryResetsAt: Date? = nil, secondaryUsedPercent: Double? = nil, secondaryResetsAt: Date? = nil, observedAt: Date) {
        self.primaryUsedPercent = primaryUsedPercent; self.primaryResetsAt = primaryResetsAt
        self.secondaryUsedPercent = secondaryUsedPercent; self.secondaryResetsAt = secondaryResetsAt; self.observedAt = observedAt
    }
}

public enum CodexUsage {
    /// Newest `rate_limits` snapshot from `token_count` events in the `files` most recently modified rollouts.
    public static func latest(root: URL = CodexHistory.defaultRoot, files: Int = 10) -> CodexLimits? {
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return CodexHistory.rollouts(root).map { ($0, mtime($0)) }.sorted { $0.1 > $1.1 }.prefix(files)
            .compactMap { latest(in: $0.0) }.max { $0.observedAt < $1.observedAt }
    }

    static func latest(in url: URL) -> CodexLimits? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let marker = Data("\"rate_limits\"".utf8)
        return JSONL.lines(data).reversed().lazy.filter { $0.range(of: marker) != nil }.compactMap { limits(JSONL.object($0)) }.first
    }

    /// Handles `primary: {used_percent, resets_at | resets_in_seconds}` and the older flat `primary_used_percent` shape.
    static func limits(_ o: [String: Any]?) -> CodexLimits? {
        guard let o, let p = o["payload"] as? [String: Any], p["type"] as? String == "token_count",
              let rl = p["rate_limits"] as? [String: Any], let at = JSONL.date(o["timestamp"]) else { return nil }
        func window(_ k: String) -> (used: Double, resets: Date?)? {
            let w = rl[k] as? [String: Any]
                ?? Dictionary(uniqueKeysWithValues: rl.compactMap { $0.key.hasPrefix(k + "_") ? (String($0.key.dropFirst(k.count + 1)), $0.value) : nil })
            guard let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let resets = JSONL.date(w["resets_at"]) ?? (w["resets_in_seconds"] as? NSNumber).map { at + $0.doubleValue }
            return (used, resets)
        }
        let primary = window("primary"), secondary = window("secondary")
        guard primary != nil || secondary != nil else { return nil }
        return CodexLimits(primaryUsedPercent: primary?.used, primaryResetsAt: primary?.resets,
                           secondaryUsedPercent: secondary?.used, secondaryResetsAt: secondary?.resets, observedAt: at)
    }
}
