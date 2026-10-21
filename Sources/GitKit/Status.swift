import Foundation
import Core

extension Git {
    /// Parse `git status --porcelain=v2 -z`: entries end in NUL, paths are as they are (no quoting), and a rename's
    /// entry is followed by its old path. Renames report the new path.
    public static func parseStatus(_ s: String) -> [FileChange] {
        var out: [FileChange] = [], oldPath = false
        for l in s.split(separator: "\0") {
            if oldPath { oldPath = false; continue }
            oldPath = l.hasPrefix("2")
            let f = l.split(separator: " ", maxSplits: l.hasPrefix("2") ? 9 : (l.hasPrefix("u") ? 10 : 8), omittingEmptySubsequences: false)
            switch l.first {
            case "1" where f.count >= 9:
                let xy = Array(f[1]).map(String.init); out.append(FileChange(path: String(f[8]), index: xy[0], worktree: xy[1]))
            case "2" where f.count >= 10:
                let xy = Array(f[1]).map(String.init); out.append(FileChange(path: String(f[9]), index: xy[0], worktree: xy[1]))
            case "u" where f.count >= 11:
                out.append(FileChange(path: String(f[10]), index: "U", worktree: "U"))
            case "?":
                out.append(FileChange(path: String(l.dropFirst(2)), index: "?", worktree: "?"))
            default: break
            }
        }
        return out
    }

    /// `only`: one file's status (a diff of one file mustn't walk every untracked folder in the repository).
    public static func status(_ path: String, only file: String? = nil) throws -> [FileChange] {
        parseStatus(try run(["status", "--porcelain=v2", "-z", "-uall"] + (file.map { ["--"] + literal([$0]) } ?? []), cwd: path))
    }
}
