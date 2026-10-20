import Foundation
import Core
import Agents
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
    /// Out of sight, nothing lost: its agents pause (they resume their conversations when it comes back), its tabs stay.
    /// A workspace going out of sight: agents that can resume their conversation pause (they come back with it), the
    /// rest stop. Returns once their programs are gone, so nothing writes into the folder after this.
    func pauseSessions(of wid: String) throws {
        let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
        var pids: [pid_t] = []
        for s in try store.sessions() where s.worktreeId == wid {
            guard let ls = existing(s.id) else { continue }
            pids.append(ls.pty.pid)
            if manifests.first(where: { $0.id == s.agent })?.resumeArgs.isEmpty == false {
                let paused = ls.markHibernated(); ls.pty.kill(); lock.withLock { live[s.id] = nil }; publish(paused)
            } else { ls.pty.kill() }
        }
        Self.waitGone(pids)
    }

    /// Until these processes have exited (or 3 s, for one that ignores the hangup).
    static func waitGone(_ pids: [pid_t]) {
        let end = Date().addingTimeInterval(3)
        while Date() < end, pids.contains(where: { kill($0, 0) == 0 }) { usleep(20_000) }
    }

    func archiveDesk(_ w: Worktree, _ r: Repo) throws {
        guard try store.worktrees(repo: r.id).filter({ isMain($0, r) && !$0.archived }).count > 1 else {
            throw RPCError.invalidParams("A project keeps at least one workspace.")
        }
        try pauseSessions(of: w.id)
        var a = w; a.archived = true; try store.save(a)
        notify("event.changed", "worktree")
    }

    func removeDesk(_ w: Worktree, _ r: Repo) throws {
        guard try store.worktrees(repo: r.id).filter({ isMain($0, r) }).count > 1 else {
            throw RPCError.invalidParams("A project keeps at least one workspace; remove the project instead.")
        }
        for s in try store.sessions() where s.worktreeId == w.id { discard(s) }
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
