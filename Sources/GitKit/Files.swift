import Foundation
import Core

/// Project files and search. Uses git so .gitignore is honoured exactly like in a terminal.
extension ProjectFiles {
    /// Tracked + untracked-but-not-ignored files, relative paths. A tracked file deleted from the folder is left out: git
    /// tags it "R" (one git process instead of a stat per file, and it works on a remote host too). Outside a sparse
    /// checkout's cone ("S", never checked by git) a file is kept only if it's there.
    public static func list(_ root: String) throws -> [String] {
        let lines: [Substring] = try Git.run(["ls-files", "-t", "--cached", "--others", "--deleted", "--exclude-standard", "-z"], cwd: root)
            .split(separator: "\0").filter { $0.count > 2 }
        let gone = Set(lines.filter { $0.hasPrefix("R ") }.map { $0.dropFirst(2) })
        let remote = RemoteHost.of(root) != nil
        return lines.filter { l in
            guard !l.hasPrefix("R "), !gone.contains(l.dropFirst(2)) else { return false }
            return !l.hasPrefix("S ") || remote || FileManager.default.fileExists(atPath: root + "/" + l.dropFirst(2))
        }.map { String($0.dropFirst(2)) }
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
            var a = ["--line-number", "--no-heading", "--null", "--color=never", "--max-columns=300", "--max-count=200"]
            if !regex { a.append("--fixed-strings") }
            if !caseSensitive { a.append("--ignore-case") }   // like git grep -i below (smart-case would honour capitals)
            out = try Git.run(a + ["--", query, "."], cwd: root, executable: rg, ok: [0, 1])   // 1 = no matches
        } else {
            var a = ["grep", "-n", "-z", "--untracked", "-I"]
            if !regex { a.append("-F") }
            if !caseSensitive { a.append("-i") }
            out = try Git.run(a + ["-e", query], cwd: root, ok: [0, 1])
        }
        return parseGrep(out, limit: limit)
    }

    /// `path NUL line : text` (rg --null) or `path NUL line NUL text` (git grep -z) lines: the path ends at the NUL, so a
    /// file named "a:b.txt" is found like any other.
    public static func parseGrep(_ s: String, limit: Int = .max) -> [SearchMatch] {
        var r: [SearchMatch] = []
        for l in s.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let nul = l.firstIndex(of: "\0") else { continue }
            var path = String(l[..<nul]); if path.hasPrefix("./") { path.removeFirst(2) }
            let rest = l[l.index(after: nul)...]
            guard let end = rest.firstIndex(where: { $0 == ":" || $0 == "\0" }), let n = Int(rest[..<end]) else { continue }
            r.append(SearchMatch(path: path, line: n, text: String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespaces)))
            if r.count >= limit { break }
        }
        return r
    }
}
