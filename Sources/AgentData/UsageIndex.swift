import Foundation

/// What Claude Code used, by local day, model and folder, kept up to date cheaply: each transcript is read once, then only
/// the bytes appended since (the index remembers how far it got, on disk). Lines are not parsed whole: only their small
/// `usage` object and a few fields are, so gigabytes of transcripts take seconds the first time and nothing after.
public final class UsageIndex: @unchecked Sendable {
    public struct Tally: Codable, Sendable, Equatable { public var tokens = TokenCounts(); public var cost = 0.0 }
    struct FileState: Codable { var offset: UInt64; var born: Double; var tallies: [String: Tally] }   // "day|model|cwd"
    public struct Row: Sendable { public var day: String, model: String, cwd: String; public var tally: Tally }

    private let lock = NSLock()
    private let cacheURL: URL
    private var files: [String: FileState]

    public init(cache: URL) {
        cacheURL = cache
        files = (try? JSONDecoder().decode([String: FileState].self, from: Data(contentsOf: cache))) ?? [:]
    }

    /// Reads what's new in transcripts under `roots` changed since `since`, then everything known from `since` on.
    public func rows(roots: [URL], since: Date) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        for root in roots {
            for case let f as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) ?? NSEnumerator() where f.pathExtension == "jsonl" {
                guard let v = try? f.resourceValues(forKeys: keys), (v.contentModificationDate ?? .distantPast) >= since else { continue }
                let size = UInt64(v.fileSize ?? 0)
                var st = files[f.path] ?? FileState(offset: 0, born: (v.creationDate ?? .distantPast).timeIntervalSince1970, tallies: [:])
                if size < st.offset { st = FileState(offset: 0, born: st.born, tallies: [:]) }   // rewritten
                guard size > st.offset else { continue }
                Self.read(f, into: &st)
                files[f.path] = st; changed = true
            }
        }
        if changed, let d = try? JSONEncoder().encode(files) { try? d.write(to: cacheURL, options: .atomic) }
        let first = Self.day(since)
        // These roots only (one account). The enumerator may report /private/var/… for /var/… (and the other way round).
        func plain(_ p: String) -> String { p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p }
        let prefixes = roots.map { plain($0.path) + "/" }
        let mine = files.filter { path, _ in prefixes.contains { plain(path).hasPrefix($0) } }
        return mine.values.flatMap { $0.tallies }.compactMap { key, t in
            let p = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return p.count == 3 && p[0] >= first ? Row(day: p[0], model: p[1], cwd: p[2], tally: t) : nil
        }
    }

    /// Days `from`…`to` (local, inclusive) as one block: what Usage's "today" and "this week" show.
    public static func block(_ rows: [Row], from: Date, to: Date) -> ClaudeUsage.Block {
        let a = day(from), b = day(to)
        let in_ = rows.filter { $0.day >= a && $0.day <= b }
        return ClaudeUsage.Block(start: from, end: to, tokens: in_.reduce(TokenCounts()) { $0 + $1.tally.tokens },
                                 estimatedCostUSD: in_.reduce(0) { $0 + $1.tally.cost }, models: Set(in_.map(\.model)).sorted())
    }

    /// The complete lines after `offset`; a line still being written waits for next time.
    static func read(_ url: URL, into st: inout FileState) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: st.offset)
        guard let data = try? h.readToEnd(), let last = data.lastIndex(of: 0x0A) else { return }
        let marker = Data("\"output_tokens\"".utf8)
        var seen = Set<String>()
        for line in data[..<last].split(separator: 0x0A) where line.range(of: marker) != nil {
            guard let e = entry(line), e.time >= st.born - 120 else { continue }   // older: history a resumed session copied in
            if let id = e.id, !seen.insert(id).inserted { continue }   // one response, several lines
            let key = "\(day(e.time))|\(e.model)|\(e.cwd)"
            var t = st.tallies[key] ?? Tally()
            t.tokens += e.tokens; t.cost += Pricing.cost(model: e.model, tokens: e.tokens)
            st.tallies[key] = t
        }
        st.offset += UInt64(last - data.startIndex + 1)
    }

    /// One assistant line's numbers, without parsing its (large) message content.
    static func entry(_ line: Data) -> (time: TimeInterval, model: String, cwd: String, id: String?, tokens: TokenCounts)? {
        // `"type":"assistant"` is the line's own type; the first "type" in a line is usually the message's ("message").
        guard line.range(of: assistant) != nil, let usage = object(line, after: "\"usage\":"),
              let u = try? JSONSerialization.jsonObject(with: usage) as? [String: Any],
              let ts = field(line, "timestamp").flatMap(parseTime) else { return nil }
        let model = field(line, "model") ?? "unknown"
        guard model != "<synthetic>" else { return nil }
        func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        let id = [field(line, "id"), field(line, "requestId")].compactMap { $0 }.joined(separator: ":")
        return (ts, model, field(line, "cwd") ?? "", id.isEmpty ? nil : id,
                TokenCounts(input: n("input_tokens"), output: n("output_tokens"), cacheWrite: n("cache_creation_input_tokens"), cacheRead: n("cache_read_input_tokens")))
    }

    /// The first `"name":"value"` in the line (string values only).
    static func field(_ line: Data, _ name: String) -> String? {
        guard let r = line.range(of: Data("\"\(name)\":\"".utf8)), let end = line[r.upperBound...].firstIndex(of: 0x22) else { return nil }
        return String(data: line[r.upperBound..<end], encoding: .utf8)
    }

    /// The `{…}` that follows `prefix` (braces counted; the usage object has no strings with braces).
    static func object(_ line: Data, after prefix: String) -> Data? {
        guard let r = line.range(of: Data(prefix.utf8)), line[r.upperBound...].first == 0x7B else { return nil }
        var depth = 0
        for i in r.upperBound..<line.endIndex {
            if line[i] == 0x7B { depth += 1 } else if line[i] == 0x7D { depth -= 1; if depth == 0 { return line[r.upperBound...i] } }
        }
        return nil
    }

    static let assistant = Data("\"type\":\"assistant\"".utf8)
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    nonisolated(unsafe) static let local: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static func parseTime(_ s: String) -> TimeInterval? { (iso.date(from: s) ?? ISO8601DateFormatter().date(from: s))?.timeIntervalSince1970 }
    static func day(_ t: TimeInterval) -> String { local.string(from: Date(timeIntervalSince1970: t)) }
    static func day(_ d: Date) -> String { local.string(from: d) }
}
