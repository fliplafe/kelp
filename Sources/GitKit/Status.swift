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

/// What Source Control lists, in the order it lists it: conflicts, then what's staged, then the rest.
/// A file with both staged and unstaged edits is in two sections; a conflicted one only in the first.
public struct ChangeGroups: Equatable, Sendable {
    public var merge: [FileChange], staged: [FileChange], changes: [FileChange]
}

extension Array where Element == FileChange {
    public var grouped: ChangeGroups {
        ChangeGroups(merge: filter(\.conflicted),
                     staged: filter { $0.staged && !$0.conflicted },
                     changes: filter { ($0.unstaged || $0.untracked) && !$0.conflicted })
    }
}

extension FileChange {
    /// VS Code's status letter: `inWorktree` picks which column speaks (the unstaged list shows the worktree's).
    public func letter(inWorktree: Bool, merging: Bool = false) -> String {
        if merging || conflicted { return "!" }
        if untracked { return "U" }
        switch inWorktree ? worktree : index {
        case "A": return "A"
        case "D": return "D"
        case "R": return "R"
        case "C": return "C"
        default: return "M"
        }
    }
}

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

    /// Whether file events can change what `git status` says: anything outside `.git/`, and inside it only what moves the
    /// index, HEAD or a branch (lock and object files churn during every git command, a status of ours included).
    public static func touchesStatus(_ paths: [String]) -> Bool {
        paths.contains { p in
            guard let r = p.range(of: "/.git/") else { return true }
            let rest = p[r.upperBound...]
            return rest == "index" || rest == "HEAD" || rest == "MERGE_HEAD" || rest == "packed-refs" || rest.hasPrefix("refs/")
        }
    }

    public static func status(_ path: String) throws -> [FileChange] {
        parseStatus(try run(["status", "--porcelain=v2", "-z", "-uall"], cwd: path))
    }
}
