import Foundation
import Core
import GitKit

/// Workspaces are worktree records. Every project has a main one on the repository itself
/// (its path is the repo path); the others are git worktrees on their own branches.
extension Daemon {
    static let placeholderName = #"^Workspace \d+$"#

    func isMain(_ w: Worktree, _ r: Repo) -> Bool { w.path == r.path }

    /// Projects added before workspaces existed get their main one; main workspaces follow the checked-out branch.
    func syncMainWorkspaces() throws {
        let all = try store.worktrees(repo: nil)
        for r in try store.repos() {
            let branch = (try? Git.currentBranch(r.path)) ?? r.baseBranch
            if var w = all.first(where: { isMain($0, r) }) {
                if w.branch != branch { w.branch = branch; try store.save(w) }
            } else {
                try store.save(Worktree(repoId: r.id, branch: branch, path: r.path, base: branch))
            }
        }
    }

    /// "Workspace 3" on branch "ws-3": instant, and renamed from the first prompt later (see autoTitle).
    func nextWorkspace(in r: Repo) throws -> (name: String, branch: String) {
        let taken = Set(try store.worktrees(repo: r.id).map(\.note))
        var n = 2
        while taken.contains("Workspace \(n)") || Git.branchExists(r.path, "ws-\(n)") { n += 1 }
        return ("Workspace \(n)", "ws-\(n)")
    }
}
