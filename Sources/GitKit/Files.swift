import Foundation

public struct SearchMatch: Codable, Sendable, Equatable {
    public var path: String; public var line: Int; public var text: String
}

/// Project files and search. Uses git so .gitignore is honoured exactly like in a terminal.
public enum ProjectFiles {
    /// Tracked + untracked-but-not-ignored files, relative paths.
    public static func list(_ root: String) throws -> [String] {
        let remote = RemoteHost.of(root) != nil   // its files are on the host: nothing to check here
        return try Git.run(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd: root)
            .split(separator: "\0").map(String.init).filter { remote || FileManager.default.fileExists(atPath: root + "/" + $0) }
    }

    /// Bundled or system ripgrep, else `git grep`.
    static var ripgrep: String? {
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("rg").path
        return [bundled, "/opt/homebrew/bin/rg", "/usr/local/bin/rg"].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func search(_ root: String, query: String, regex: Bool = false, caseSensitive: Bool = false, limit: Int = 2000) throws -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        var out: String
        if let rg = ripgrep, RemoteHost.of(root) == nil {   // remote: git grep runs on the host
            var a = ["--line-number", "--no-heading", "--color=never", "--max-columns=300", "--max-count=200"]
            if !regex { a.append("--fixed-strings") }
            if !caseSensitive { a.append("--ignore-case") }   // like git grep -i below (smart-case would honour capitals)
            out = try Git.run(a + ["--", query, "."], cwd: root, executable: rg, ok: [0, 1])   // 1 = no matches
        } else {
            var a = ["grep", "-n", "--untracked", "-I"]
            if !regex { a.append("-F") }
            if !caseSensitive { a.append("-i") }
            out = try Git.run(a + ["-e", query], cwd: root, ok: [0, 1])
        }
        return parseGrep(out, limit: limit)
    }

    /// `path:line:text` lines.
    public static func parseGrep(_ s: String, limit: Int = .max) -> [SearchMatch] {
        var r: [SearchMatch] = []
        for l in s.split(separator: "\n", omittingEmptySubsequences: true) {
            let p = l.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard p.count == 3, let n = Int(p[1]) else { continue }
            var path = String(p[0]); if path.hasPrefix("./") { path.removeFirst(2) }
            r.append(SearchMatch(path: path, line: n, text: String(p[2]).trimmingCharacters(in: .whitespaces)))
            if r.count >= limit { break }
        }
        return r
    }

    /// A path made ready for fuzzyScore once: Quick Open scores every file of the project on each keystroke.
    public struct FuzzyPath: Sendable {
        let bytes: [UInt8], name: Int, length: Int   // lowercased UTF-8, where the file name starts, length in characters
        public init(_ path: String) {
            bytes = Array(path.lowercased().utf8)
            name = bytes.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 } ?? 0
            length = path.count
        }
    }
    /// The query as fuzzyScore wants it.
    public static func fuzzyQuery(_ q: String) -> [UInt8] { Array(q.lowercased().utf8) }

    /// Fuzzy subsequence score for quick open (higher is better, nil = no match). Matches inside the file name win.
    public static func fuzzyScore(_ candidate: String, _ query: String) -> Int? { fuzzyScore(FuzzyPath(candidate), fuzzyQuery(query)) }

    public static func fuzzyScore(_ c: FuzzyPath, _ q: [UInt8]) -> Int? {
        if q.isEmpty { return 0 }
        let full = subsequenceScore(c.bytes[...], q), inName = subsequenceScore(c.bytes[c.name...], q).map { $0 + 100 }
        guard let best = [full, inName].compactMap({ $0 }).max() else { return nil }
        return best - c.length / 4
    }

    private static let wordStarts = Set("/._- ".utf8)
    static func subsequenceScore(_ c: ArraySlice<UInt8>, _ q: [UInt8]) -> Int? {
        var ci = c.startIndex, score = 0, streak = 0, last = -2
        for ch in q {
            guard ci < c.endIndex, let i = c[ci...].firstIndex(of: ch) else { return nil }
            streak = (i == last + 1) ? streak + 1 : 0
            score += 10 + streak * 5
            if i == c.startIndex || wordStarts.contains(c[i - 1]) { score += 15 }   // word start
            last = i; ci = i + 1
        }
        return score
    }
}
