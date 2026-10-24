import Foundation

/// Claude Code prints plan usage in its UI ("You've used 80% of your weekly limit · resets Oct 20 at 5am (Europe/…)").
/// There's no other local source for those percentages, so sessions read them from their own output.
public enum ClaudeLimits {
    public struct Reading: Equatable, Sendable {
        public var kind: String       // "weekly", "session", "5-hour", "Opus weekly"…
        public var percent: Double
        public var resets: String?
    }

    private static let used = try? NSRegularExpression(pattern: #"(\d{1,3})% of your ([A-Za-z0-9\- ]{1,30}?) limit(?:\s*[·∙•|-]\s*resets ([^\n(·]{2,40}))?"#)
    private static let reached = try? NSRegularExpression(pattern: #"([A-Za-z0-9\- ]{1,30}?) limit reached(?:\s*[·∙•|-]\s*resets ([^\n(·]{2,40}))?"#,
                                                          options: .caseInsensitive)

    public static func parse(_ text: String) -> [Reading] {
        let r = NSRange(text.startIndex..., in: text)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            Range(m.range(at: i), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
        var out = (used?.matches(in: text, range: r) ?? []).compactMap { m -> Reading? in
            guard let p = group(m, 1).flatMap(Double.init), let kind = group(m, 2) else { return nil }
            return Reading(kind: kind, percent: min(p, 100), resets: group(m, 3))
        }
        out += (reached?.matches(in: text, range: r) ?? []).compactMap { m in
            group(m, 1).map { Reading(kind: $0.replacingOccurrences(of: "Claude AI usage", with: "usage"), percent: 100, resets: group(m, 2)) }
        }
        return out
    }

    /// Claude Code's `/usage` screen: "Current session … 2% used · Resets 7:40am", "Current week (all models) … 82% used · Resets Oct 20 at 5am",
    /// "Current week (Fable) …". The screen redraws while it loads, so the last reading of each limit wins.
    public static func parseUsageScreen(_ text: String) -> [Reading] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var found: [String: Reading] = [:]
        var order: [String] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("Current ") && !line.contains("%") {
            let label = String(line.dropFirst("Current ".count))
            let kind = label == "session" ? "session"
                : label.hasPrefix("week (all") ? "week"
                : label.hasPrefix("week (") ? "week · " + label.dropFirst(6).dropLast() : label
            var percent: Double?, resets: String?
            for next in lines[(i + 1)..<min(i + 4, lines.count)] {
                if next.hasPrefix("Current ") { break }
                if percent == nil, let r = next.range(of: #"(\d{1,3})% used"#, options: .regularExpression) {
                    percent = Double(next[r].prefix { $0.isNumber })
                } else if resets == nil, next.hasPrefix("Resets ") {
                    resets = String(next.dropFirst("Resets ".count)).replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
                }
            }
            guard let percent else { continue }
            if found[kind] == nil { order.append(kind) }
            found[kind] = Reading(kind: kind, percent: percent, resets: resets)
        }
        return order.compactMap { found[$0] }
    }

    /// Grok Build's `/usage` dialog: "Weekly limit (X Premium)", a bar with "45%", "Resets: October 24, 19:36".
    public static func parseGrokUsage(_ text: String) -> [Reading] {
        let lines = cells(text)
        guard let i = lines.lastIndex(where: { $0.hasPrefix("Weekly limit") }) else { return [] }
        var percent: Double?, resets: String?
        for next in lines[(i + 1)..<min(i + 4, lines.count)] {
            if percent == nil, let r = next.range(of: #"\d{1,3}(\.\d+)?%"#, options: .regularExpression) { percent = Double(next[r].dropLast()) }
            if next.hasPrefix("Resets:") { resets = next.dropFirst("Resets:".count).trimmingCharacters(in: .whitespaces) }
        }
        return percent.map { [Reading(kind: "week", percent: $0, resets: resets)] } ?? []
    }

    /// Antigravity's `/usage`: per model group ("GEMINI MODELS", "CLAUDE AND GPT MODELS") a weekly limit *remaining*;
    /// returned as used, like the others ("Gemini week" 12 = 88% left).
    public static func parseAntigravityUsage(_ text: String) -> [Reading] {
        let lines = cells(text)
        var found: [String: Reading] = [:], order: [String] = []
        for (i, line) in lines.enumerated() where line.hasSuffix(" MODELS") && line == line.uppercased() {
            let group = line.dropLast(" MODELS".count).split(separator: " ").first.map { $0.capitalized } ?? "Models"
            var percent: Double?, resets: String?
            for next in lines[(i + 1)..<min(i + 6, lines.count)] {
                if next.hasSuffix(" MODELS") { break }
                if percent == nil, let r = next.range(of: #"\d{1,3}(\.\d+)?%"#, options: .regularExpression) { percent = Double(next[r].dropLast()) }
                if let r = next.range(of: #"(?i)resets in .*"#, options: .regularExpression) { resets = String(next[r].dropFirst("resets ".count)) }
            }
            guard let left = percent else { continue }
            let kind = "\(group) week"
            if found[kind] == nil { order.append(kind) }
            found[kind] = Reading(kind: kind, percent: (100 - left).rounded(), resets: resets)
        }
        return order.compactMap { found[$0] }
    }

    /// A TUI's text in pieces: lines, split again at dialog borders (│) and wide gaps between columns.
    static func cells(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n│┃║"))
            .flatMap { $0.components(separatedBy: "   ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
