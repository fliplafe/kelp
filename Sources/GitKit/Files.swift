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
            if !caseSensitive { a.append("--smart-case") }
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

    /// Fuzzy subsequence score for quick open (higher is better, nil = no match). Matches inside the file name win.
    public static func fuzzyScore(_ candidate: String, _ query: String) -> Int? {
        if query.isEmpty { return 0 }
        let full = subsequenceScore(Array(candidate.lowercased()), Array(query.lowercased()))
        let name = (candidate as NSString).lastPathComponent
        let inName = subsequenceScore(Array(name.lowercased()), Array(query.lowercased())).map { $0 + 100 }
        guard let best = [full, inName].compactMap({ $0 }).max() else { return nil }
        return best - candidate.count / 4
    }

    static func subsequenceScore(_ c: [Character], _ q: [Character]) -> Int? {
        var ci = 0, score = 0, streak = 0, last = -2
        for ch in q {
            guard ci < c.count, let i = c[ci...].firstIndex(of: ch) else { return nil }
            streak = (i == last + 1) ? streak + 1 : 0
            score += 10 + streak * 5
            if i == 0 || "/._- ".contains(c[i - 1]) { score += 15 }   // word start
            last = i; ci = i + 1
        }
        return score
    }
}
