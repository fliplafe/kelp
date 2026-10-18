import Foundation
import Core

public enum ReviewMessage {
    /// All open comments as one message for the agent: file, lines, code quote, remark.
    public static func compose(branch: String, comments: [DiffComment]) -> String {
        var s = "Review comments on branch \(branch). Please address each one:\n"
        for (i, c) in comments.enumerated() {
            let range = c.startLine == c.endLine ? "\(c.startLine)" : "\(c.startLine)-\(c.endLine)"
            s += "\n\(i + 1). \(c.file):\(range)\n"
            for l in c.quote.split(separator: "\n", omittingEmptySubsequences: false) { s += "   > \(l)\n" }
            s += "   \(c.text)\n"
        }
        return s
    }
}

/// `.krill.yaml`: flat `key: value` lines (setup, run, test). Deliberately not full YAML.
public struct RepoConfig: Sendable, Equatable {
    public var setup: String?, run: String?, test: String?
    public static func parse(_ text: String) -> RepoConfig {
        var c = RepoConfig()
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let i = t.firstIndex(of: ":") else { continue }
            var v = t[t.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) { v = String(v.dropFirst().dropLast()) }
            switch t[..<i] { case "setup": c.setup = v; case "run": c.run = v; case "test": c.test = v; default: break }
        }
        return c
    }
    public static func load(repoPath: String) -> RepoConfig {
        parse((try? String(contentsOfFile: repoPath + "/.krill.yaml", encoding: .utf8)) ?? "")
    }
}
