import Foundation
import Core
import GitKit

// Source control, files and review comments: everything runs here, off the UI.

extension GitStatus: Handled { func handle(_ d: Daemon) throws -> Result { try Git.status(d.cwd(forWorktree: id).path) } }
extension GitBranches: Handled { func handle(_ d: Daemon) throws -> Result { try Git.branches(d.cwd(forWorktree: id).path) } }
extension GitLineStats: Handled { func handle(_ d: Daemon) throws -> Result { try Git.lineStats(d.cwd(forWorktree: id).path) } }
/// The branch checked out now (a workspace's record can be stale after a switch).
extension GitPush: Handled { func handle(_ d: Daemon) throws -> Done { try Git.remote(d.cwd(forWorktree: id).path, .push); return Done() } }

extension GitDiff: Handled {
    func handle(_ d: Daemon) throws -> Result {
        let w = try d.cwd(forWorktree: id)
        var dir = w.path
        let src: DiffSource
        switch source ?? "all" {
        case "turn":   // since the agent's last turn started, where it worked then (its own worktree, maybe)
            guard let s = session, let ls = d.existing(s), let base = ls.turnBase else {
                throw RPCError.invalidParams("That agent hasn't started a turn since Kelp launched.")
            }
            src = .since(tree: base); dir = ls.turnDir ?? dir
        case "unstaged": src = .unstaged
        case "staged": src = .staged
        case "branch": src = .branch(base: try d.ref(base) ?? (try d.store.repo(w.repoId)?.baseBranch ?? "main"))
        case "commit":
            guard let commit else { throw RPCError.invalidParams("missing commit") }
            src = .commit(try d.ref(commit) ?? "")
        default: src = .allUncommitted
        }
        return try Git.diff(dir, source: src, file: file)
    }
}

extension GitLog: Handled {
    func handle(_ d: Daemon) throws -> Result {
        let w = try d.cwd(forWorktree: id)
        let base = all == true ? nil : try d.store.repo(w.repoId)?.baseBranch
        return try Git.log(w.path, base: base).map { Entry(hash: $0.hash, subject: $0.subject) }
    }
}

extension GitStage: Handled { func handle(_ d: Daemon) throws -> Done { try Git.stage(d.cwd(forWorktree: id).path, files: files ?? []); return Done() } }
extension GitUnstage: Handled { func handle(_ d: Daemon) throws -> Done { try Git.unstage(d.cwd(forWorktree: id).path, files: files ?? []); return Done() } }

extension GitHunk: Handled {
    func handle(_ d: Daemon) throws -> Done {
        let w = try d.cwd(forWorktree: id), rev = reverse == true
        let diff = try Git.diff(w.path, source: rev ? .staged : .unstaged, file: file).first
        // With its fingerprint, the hunk as shown line for line; with its header, that one; else by number.
        let i = fingerprint.map { f in diff?.hunks.firstIndex { $0.fingerprint == f } ?? -1 }
            ?? header.map { h in diff?.hunks.firstIndex { $0.header == h } ?? -1 } ?? hunk ?? -1
        guard let diff, diff.hunks.indices.contains(i) else {
            throw RPCError.invalidParams(rev ? "The file changed since it was shown; nothing was unstaged." : "The file changed since it was shown; nothing was staged.")
        }
        try Git.applyHunk(w.path, diff: diff, hunk: i, reverse: rev)
        return Done()
    }
}

extension GitCommit: Handled {
    func handle(_ d: Daemon) throws -> String {
        try Git.commit(d.cwd(forWorktree: id).path, message: message, all: all == true, amend: amend == true)
    }
}

extension GitMerge: Handled {
    func handle(_ d: Daemon) throws -> Result {
        let w = try d.cwd(forWorktree: id)
        guard let r = try d.store.repo(w.repoId) else { throw RPCError.invalidParams("no repo") }
        if try Git.isDirty(w.path) { throw RPCError.invalidParams("worktree has uncommitted changes") }
        // The main checkout too: a merge (and the abort a conflict brings) must never touch the user's own work there.
        if Git.isMerging(r.path) { throw RPCError.invalidParams("The main checkout is in the middle of a merge. Finish or abort it first.") }
        if try Git.isDirty(r.path) { throw RPCError.invalidParams("The main checkout has uncommitted changes. Commit or stash them first.") }
        // The branch checked out in the desk now (a switch makes the record stale), into the base and only the base.
        let branch = (try? Git.currentBranch(w.path)) ?? w.branch
        // Detached: "HEAD" would merge the main checkout into itself ("Already up to date") and report success.
        guard branch != "HEAD" else {
            throw RPCError.invalidParams("This workspace isn't on a branch (detached HEAD). Create a branch for its commits, then merge.")
        }
        let res = try Git.merge(branch: branch, into: r.path, onto: r.baseBranch, keepConflicts: keepConflicts == true)
        return Result(merged: res.merged, conflicts: res.conflicts)
    }
}

extension GitSwitch: Handled {
    func handle(_ d: Daemon) throws -> Done {
        try Git.switchBranch(d.cwd(forWorktree: id).path, to: d.ref(branch) ?? "", create: create == true, remote: remote == true)
        return Done()
    }
}

extension GitGraph: Handled {
    func handle(_ d: Daemon) throws -> Result {
        let g = try Git.graph(d.cwd(forWorktree: id).path, limit: max(1, limit ?? 200))
        return Result(commits: g.commits, more: g.more)
    }
}

extension GitCommitFiles: Handled {
    func handle(_ d: Daemon) throws -> Result { try Git.commitFiles(d.cwd(forWorktree: id).path, commit: d.ref(commit) ?? "") }
}
extension GitDiscard: Handled { func handle(_ d: Daemon) throws -> Done { try Git.discard(d.cwd(forWorktree: id).path, files: files ?? []); return Done() } }

extension GitRemoteOp: Handled {
    func handle(_ d: Daemon) throws -> Done {
        guard let o = Git.Remote(rawValue: op) else { throw RPCError.invalidParams("op: pull, push or fetch") }
        try Git.remote(d.cwd(forWorktree: id).path, o)
        return Done()
    }
}
extension GitStash: Handled { func handle(_ d: Daemon) throws -> Done { try Git.stash(d.cwd(forWorktree: id).path, pop: pop == true); return Done() } }

extension GitWebURL: Handled {
    func handle(_ d: Daemon) throws -> String {
        let last = end ?? start
        return try Git.webURL(path: path, lines: start.flatMap { s in last.map { min(s, $0)...max(s, $0) } })
    }
}

extension FilesList: Handled { func handle(_ d: Daemon) throws -> Result { try ProjectFiles.list(d.cwd(forWorktree: id).path) } }
extension FilesSearch: Handled {
    func handle(_ d: Daemon) throws -> Result {
        try ProjectFiles.search(d.cwd(forWorktree: id).path, query: query, regex: regex == true, caseSensitive: `case` == true)
    }
}

extension CommentAdd: Handled {
    func handle(_ d: Daemon) throws -> DiffComment {
        let c = DiffComment(worktreeId: id, file: file, startLine: start ?? 1, endLine: end ?? start ?? 1, quote: quote ?? "", text: text)
        try d.store.save(c)
        return c
    }
}
extension CommentList: Handled { func handle(_ d: Daemon) throws -> Result { try d.store.comments(worktree: id) } }
extension CommentSetState: Handled {
    func handle(_ d: Daemon) throws -> Done {
        guard var c = try d.store.db.read({ try DiffComment.fetchOne($0, key: id) }) else { throw RPCError.invalidParams("no comment") }
        c.state = DiffComment.State(rawValue: state) ?? .open
        try d.store.save(c)
        return Done()
    }
}
/// All open comments → one message into the agent's terminal.
extension CommentSend: Handled {
    func handle(_ d: Daemon) throws -> Int {
        let w = try d.cwd(forWorktree: id)
        let open = try d.store.comments(worktree: w.id).filter { $0.state == .open }
        guard !open.isEmpty else { return 0 }
        _ = try SessionSend(id: session, text: Self.message(branch: w.branch, comments: open)).handle(d)
        for var c in open { c.state = .sent; try d.store.save(c) }
        return open.count
    }

    /// File, lines, code quote, remark for each.
    private static func message(branch: String, comments: [DiffComment]) -> String {
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

extension Daemon {
    static let gitMethods: [any Handled.Type] = [GitStatus.self, GitBranches.self, GitLineStats.self, GitPush.self, GitDiff.self, GitLog.self,
        GitStage.self, GitUnstage.self, GitHunk.self, GitCommit.self, GitMerge.self, GitSwitch.self, GitGraph.self, GitCommitFiles.self,
        GitDiscard.self, GitRemoteOp.self, GitStash.self, GitWebURL.self, FilesList.self, FilesSearch.self,
        CommentAdd.self, CommentList.self, CommentSetState.self, CommentSend.self]
}
