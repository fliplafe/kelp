import Foundation

/// Claude Code prints plan usage in its UI ("You've used 80% of your weekly limit · resets Oct 20 at 5am (Europe/…)").
/// There's no other local source for those percentages, so sessions read them from their own output.
public enum ClaudeLimits {
    public struct Reading: Equatable, Sendable {
        public var kind: String       // "weekly", "session", "5-hour", "Opus weekly"…
        public var percent: Double
        public var resets: String?
    }

    // swiftlint:disable:next force_try
    private static let used = try! NSRegularExpression(pattern: #"(\d{1,3})% of your ([A-Za-z0-9\- ]{1,30}?) limit(?:\s*[·∙•|-]\s*resets ([^\n(·]{2,40}))?"#)
    // swiftlint:disable:next force_try
    private static let reached = try! NSRegularExpression(pattern: #"([A-Za-z0-9\- ]{1,30}?) limit reached(?:\s*[·∙•|-]\s*resets ([^\n(·]{2,40}))?"#, options: .caseInsensitive)

    public static func parse(_ text: String) -> [Reading] {
        let r = NSRange(text.startIndex..., in: text)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            Range(m.range(at: i), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
        var out = used.matches(in: text, range: r).compactMap { m -> Reading? in
            guard let p = group(m, 1).flatMap(Double.init), let kind = group(m, 2) else { return nil }
            return Reading(kind: kind, percent: min(p, 100), resets: group(m, 3))
        }
        out += reached.matches(in: text, range: r).compactMap { m in
            group(m, 1).map { Reading(kind: $0.replacingOccurrences(of: "Claude AI usage", with: "usage"), percent: 100, resets: group(m, 2)) }
        }
        return out
    }
}
