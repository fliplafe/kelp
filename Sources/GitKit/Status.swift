import Foundation

public struct FileChange: Codable, Sendable, Equatable {
    public var path: String
    public var index: String   // staged status column
    public var worktree: String
    public var staged: Bool { index != "." && index != "?" }
    public var unstaged: Bool { worktree != "." }
    public var untracked: Bool { index == "?" }
    public var conflicted: Bool { index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") }
}

extension Git {
    /// Parse `git status --porcelain=v2`. Renames report the new path.
    public static func parseStatus(_ s: String) -> [FileChange] {
        var out: [FileChange] = []
        for l in s.split(separator: "\n") {
            let f = l.split(separator: " ", maxSplits: l.hasPrefix("2") ? 9 : (l.hasPrefix("u") ? 10 : 8), omittingEmptySubsequences: false)
            switch l.first {
            case "1" where f.count >= 9:
                let xy = Array(f[1]).map(String.init); out.append(FileChange(path: String(f[8]), index: xy[0], worktree: xy[1]))
            case "2" where f.count >= 10:
                let xy = Array(f[1]).map(String.init); let p = f[9].split(separator: "\t").first.map(String.init) ?? String(f[9])
                out.append(FileChange(path: p, index: xy[0], worktree: xy[1]))
            case "u" where f.count >= 11:
                out.append(FileChange(path: String(f[10]), index: "U", worktree: "U"))
            case "?":
                out.append(FileChange(path: String(l.dropFirst(2)), index: "?", worktree: "?"))
            default: break
            }
        }
        return out
    }

    public static func status(_ path: String) throws -> [FileChange] {
        parseStatus(try run(["status", "--porcelain=v2", "-uall"], cwd: path))
    }
}
