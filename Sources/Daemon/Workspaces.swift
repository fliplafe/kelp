import Foundation
import Core
import GitKit

/// Workspaces are worktree records. A workspace is a desk in the project's folder (its path is the repo path): a set of
/// tabs and agents, nothing on disk. Several desks can share the folder. Workspaces from older versions may still be
/// git worktrees on their own branches.
extension Daemon {
    static let placeholderName = #"^Workspace \d+$"#

    func isMain(_ w: Worktree, _ r: Repo) -> Bool { w.path == r.path }

    /// Every project keeps at least one desk; desks follow the folder's checked-out branch.
    func syncMainWorkspaces() throws {
        let all = try store.worktrees(repo: nil)
        for r in try store.repos() {
            let branch = (try? Git.currentBranch(r.path)) ?? r.baseBranch
            let desks = all.filter { isMain($0, r) }
            if desks.isEmpty { try store.save(Worktree(repoId: r.id, branch: branch, path: r.path, note: "Workspace 1", base: branch)) }
            for var w in desks where w.branch != branch || w.note.isEmpty {
                w.branch = branch
                if w.note.isEmpty { w.note = "Workspace 1" }   // was the project's "main" workspace
                try store.save(w)
            }
        }
    }

    /// A new desk in the project's folder: instant, named "Workspace N" until its first prompt names it (see autoTitle).
    func createDesk(in r: Repo) throws -> Worktree {
        try syncMainWorkspaces()   // names the project's first desk, so the new one doesn't take "Workspace 1"
        let taken = Set(try store.worktrees(repo: r.id).map(\.note))
        var n = 1
        while taken.contains("Workspace \(n)") { n += 1 }
        let branch = (try? Git.currentBranch(r.path)) ?? r.baseBranch
        let w = Worktree(repoId: r.id, branch: branch, path: r.path, note: "Workspace \(n)", base: branch)
        try store.save(w)
        notify("event.changed", "worktree")
        return w
    }

    /// Closing a desk ends its agents and forgets its layout; the folder is untouched. The last one stays.
    func removeDesk(_ w: Worktree, _ r: Repo) throws {
        guard try store.worktrees(repo: r.id).filter({ isMain($0, r) }).count > 1 else {
            throw RPCError.invalidParams("A project keeps at least one workspace; remove the project instead.")
        }
        for s in try store.sessions() where s.worktreeId == w.id { existing(s.id)?.pty.kill(); try? store.delete(s) }
        try store.delete(w)
        notify("event.changed", "worktree")
    }

    /// "Workspace 3" on branch "ws-3": instant, and renamed from the first prompt later (see autoTitle).
    func nextWorkspace(in r: Repo) throws -> (name: String, branch: String) {
        let taken = Set(try store.worktrees(repo: r.id).map(\.note))
        var n = 2
        while taken.contains("Workspace \(n)") || Git.branchExists(r.path, "ws-\(n)") { n += 1 }
        return ("Workspace \(n)", "ws-\(n)")
    }
}
