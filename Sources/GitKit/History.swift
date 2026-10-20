import Foundation

/// One row of the commit graph (VS Code's Source Control Graph). Lines are lane pairs:
/// `top` runs from the row's top edge (lane `[0]`) to its middle (lane `[1]`), `bottom` from the middle to the bottom edge.
public struct GraphCommit: Codable, Sendable, Equatable {
    public var hash: String
    public var parents: [String]
    public var author: String
    public var date: Double
    public var subject: String
    /// `git log %D` items: "HEAD -> main", "origin/main", "tag: v1.0".
    public var refs: [String]
    public var lane: Int
    public var top: [[Int]]
    public var bottom: [[Int]]
}

public struct BranchInfo: Codable, Sendable, Equatable {
    public var current: String?        // nil when HEAD is detached
    public var head: String?           // short hash of HEAD (nil before the first commit)
    public var local: [String]
    public var remote: [String]
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var merging: Bool
}

extension Git {
    /// Lanes for commits in topological order (children before parents). A commit takes the lane that was waiting for it
    /// (or the first free one); its first parent continues there, other parents join their lane or open a new one.
    public static func lanes(_ commits: [(hash: String, parents: [String])]) -> [(lane: Int, top: [[Int]], bottom: [[Int]])] {
        var lanes: [String?] = []
        var out: [(lane: Int, top: [[Int]], bottom: [[Int]])] = []
        for c in commits {
            let col = lanes.firstIndex(of: c.hash) ?? lanes.firstIndex(of: nil) ?? lanes.count
            var top: [[Int]] = [], through: [Int] = []
            for (i, h) in lanes.enumerated() {
                guard let h else { continue }
                if h == c.hash { top.append([i, col]) } else { top.append([i, i]); through.append(i) }
            }
            if col == lanes.count { lanes.append(nil) }
            for i in lanes.indices where lanes[i] == c.hash { lanes[i] = nil }
            var bottom = through.map { [$0, $0] }
            for (n, p) in c.parents.enumerated() {
                // An already-waiting parent is joined, except that a first parent waiting further right comes to this lane:
                // the trunk stays leftmost and the right lane converges into it at the parent's row.
                if let k = lanes.firstIndex(of: p), n > 0 || k < col { bottom.append([col, k]); continue }
                let k = n == 0 ? col : (lanes.firstIndex(of: nil) ?? lanes.count)
                if k == lanes.count { lanes.append(p) } else { lanes[k] = p }
                bottom.append([col, k])
            }
            while lanes.last == .some(nil) { lanes.removeLast() }
            out.append((col, top, bottom))
        }
        return out
    }

    /// Commits no remote branch has. Topological order lists a commit before its ancestors, so one pass down from the
    /// remote branches' tips marks everything they reach; what's left is local only. No remotes: nothing to mark.
    public static func unpushed(_ commits: [GraphCommit], remotes: Set<String>) -> Set<String> {
        guard !remotes.isEmpty else { return [] }
        var pushed = Set<String>(), out = Set<String>()
        for c in commits {
            if pushed.contains(c.hash) || c.refs.contains(where: remotes.contains) { pushed.formUnion(c.parents) } else { out.insert(c.hash) }
        }
        return out
    }

    /// The first `limit` commits of every branch, tag and remote, newest first, with graph lanes.
    public static func graph(_ path: String, limit: Int) throws -> (commits: [GraphCommit], more: Bool) {
        let fmt = "%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s%x1e"
        let raw = try run(["log", "--topo-order", "--format=\(fmt)", "-n\(limit + 1)", "--branches", "--tags", "--remotes", "HEAD"], cwd: path)
        var rows: [(String, [String], String, Double, [String], String)] = []
        for rec in raw.split(separator: "\u{1e}") {
            let f = rec.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6 else { continue }
            rows.append((f[0], f[1].split(separator: " ").map(String.init), f[2], Double(f[3]) ?? 0,
                         f[4].isEmpty ? [] : f[4].components(separatedBy: ", "), f[5]))
        }
        let more = rows.count > limit
        rows = Array(rows.prefix(limit))
        let l = lanes(rows.map { ($0.0, $0.1) })
        return (zip(rows, l).map { r, g in
            GraphCommit(hash: r.0, parents: r.1, author: r.2, date: r.3, subject: r.5, refs: r.4, lane: g.lane, top: g.top, bottom: g.bottom)
        }, more)
    }

    /// Files a commit changed against its first parent: `[(status letter, path)]`.
    /// `-z`: "M\0path\0" or, renamed or copied, "R100\0old\0new\0".
    public static func commitFiles(_ path: String, commit: String) throws -> [FileChange] {
        var f = try run(["show", "--format=", "--name-status", "-z", "-M", "--diff-merges=first-parent", commit], cwd: path)
            .split(separator: "\0").map(String.init)[...]
        var out: [FileChange] = []
        while let s = f.popFirst()?.first {
            let n = s == "R" || s == "C" ? 2 : 1
            guard let p = f.prefix(n).last else { break }
            f = f.dropFirst(n)
            out.append(FileChange(path: p, index: String(s), worktree: "."))
        }
        return out
    }

    /// Source Control reads this on every change in the folder: one for-each-ref answers what took five git processes
    /// (each an ssh round trip for a remote project). Detached or before the first commit, HEAD is asked for itself.
    public static func branches(_ path: String) throws -> BranchInfo {
        let refs = try run(["for-each-ref", "--format=%(HEAD)%00%(refname)%00%(objectname:short)%00%(upstream:short)%00%(upstream:track,nobracket)",
                            "refs/heads", "refs/remotes"], cwd: path)
        var b = BranchInfo(current: nil, head: nil, local: [], remote: [], upstream: nil, ahead: nil, behind: nil, merging: false)
        for line in refs.split(separator: "\n") {
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { continue }
            if f[1].hasPrefix("refs/remotes/") {
                if !f[1].hasSuffix("/HEAD") { b.remote.append(String(f[1].dropFirst("refs/remotes/".count))) }
                continue
            }
            let name = String(f[1].dropFirst("refs/heads/".count))
            b.local.append(name)
            guard f[0] == "*" else { continue }
            b.current = name; b.head = f[2]
            guard !f[3].isEmpty, f[4] != "gone" else { continue }   // "gone": the upstream branch was deleted
            b.upstream = f[3]; b.ahead = 0; b.behind = 0
            for part in f[4].split(separator: ",") {   // "ahead 2, behind 1"; "" when even
                let w = part.split(separator: " ")
                if w.count == 2, w[0] == "ahead" { b.ahead = Int(w[1]) } else if w.count == 2, w[0] == "behind" { b.behind = Int(w[1]) }
            }
        }
        if b.current == nil {
            let c = try run(["symbolic-ref", "--short", "-q", "HEAD"], cwd: path, ok: [0, 1]).trimmingCharacters(in: .whitespacesAndNewlines)
            b.current = c.isEmpty ? nil : c
            b.head = (try? run(["rev-parse", "--short", "HEAD"], cwd: path))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        b.merging = (try? run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], cwd: path)) != nil
        return b
    }

    /// Switch to a local branch, a remote one (creates the tracking branch), or a new one.
    public static func switchBranch(_ path: String, to name: String, create: Bool = false, remote: Bool = false) throws {
        if create { try run(["switch", "-c", name], cwd: path); return }
        try run(["switch", remote ? String(name.drop { $0 != "/" }.dropFirst()) : name], cwd: path)
    }

    /// Undo working-tree changes: tracked files go back to the index, untracked files are deleted.
    public static func discard(_ path: String, files: [String]) throws {
        let untracked = Set(try status(path).filter(\.untracked).map(\.path))
        let (u, t) = (files.filter { untracked.contains($0) }, files.filter { !untracked.contains($0) })
        if !u.isEmpty { try run(["clean", "-f", "-q", "--"] + literal(u), cwd: path) }
        if !t.isEmpty { try run(["restore", "--worktree", "--"] + literal(t), cwd: path) }
    }

    public enum Remote: String, Sendable { case pull, push, fetch }

    public static func remote(_ path: String, _ op: Remote) throws {
        switch op {
        case .pull: try run(["pull"], cwd: path)
        case .fetch: try run(["fetch", "--all", "--prune"], cwd: path)
        case .push:
            let b = try currentBranch(path)
            let hasUpstream = (try? run(["rev-parse", "--abbrev-ref", "@{upstream}"], cwd: path)) != nil
            try run(hasUpstream ? ["push"] : ["push", "-u", "origin", b], cwd: path)
        }
    }

    /// Pop puts staged changes back as staged when it can (`--index`), like VS Code.
    public static func stash(_ path: String, pop: Bool) throws {
        guard pop else { try run(["stash", "push", "--include-untracked"], cwd: path); return }
        if (try? run(["stash", "pop", "--index"], cwd: path)) == nil { try run(["stash", "pop"], cwd: path) }
    }
}
