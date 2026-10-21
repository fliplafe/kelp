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
        deskLock.lock(); defer { deskLock.unlock() }
        let all = try store.worktrees(repo: nil)
        for r in try store.repos() {
            let desks = all.filter { isMain($0, r) }
            // A remote project's branch is read over ssh: not on every list (an unreachable host would stall each one for
            // its connect timeout). Its desks keep the branch they have; git.status and the like read it when asked.
            if RemoteHost.of(r.path) != nil, !desks.isEmpty { continue }
            let branch = RemoteHost.of(r.path) != nil ? r.baseBranch : (try? Git.currentBranch(r.path)) ?? r.baseBranch
            if desks.isEmpty { try store.save(Worktree(repoId: r.id, branch: branch, path: r.path, note: "Workspace 1", base: branch)) }
            for w in desks where w.branch != branch || w.note.isEmpty {
                try store.update(Worktree.self, w.id) {
                    $0.branch = branch
                    if $0.note.isEmpty { $0.note = "Workspace 1" }   // was the project's "main" workspace
                }
            }
        }
    }

    /// A new desk in the project's folder: instant, named "Workspace N" until its first prompt names it (see autoTitle).
    func createDesk(in r: Repo) throws -> Worktree {
        deskLock.lock(); defer { deskLock.unlock() }   // its "Workspace N" counts the desks there now
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
        // Under their wake locks, as idle pausing is: a wake that comes meanwhile waits until the programs are gone instead
        // of starting a second one (on the same log, in a folder about to be removed).
        let sessions = try store.sessions().filter { $0.worktreeId == wid }
        try wakeLocks.withLocks(sessions.map(\.id)) {
            for s in sessions { if let ls = live.remove(s.id) { pids += pause(ls, manifests) } }
            Self.waitGone(pids)
        }
    }

    /// A session already out of `live`: recorded as paused (a resumable agent) or ended — said here and saved now, since
    /// nothing records its exit any more — then stopped with all it started. Its pids, for `waitGone`.
    func pause(_ ls: LiveSession, _ manifests: [AgentManifest]) -> [pid_t] {
        if manifests.first(where: { $0.id == ls.snapshot.agent })?.resumeArgs.isEmpty == false {
            publish(ls.markHibernated())
        } else {
            ls.overrideStatus(.exited); publish(ls.snapshot)
        }
        return ls.pty.terminate()   // SIGKILL after 2 s for what ignores the hangup, so all is gone within waitGone's 3
    }

    /// Until these processes have exited (or 3 s, for one that ignores the hangup).
    static func waitGone(_ pids: [pid_t]) {
        let end = Date().addingTimeInterval(3)
        while Date() < end, pids.contains(where: { kill($0, 0) == 0 }) { usleep(20_000) }
    }

    /// Archiving keeps the folder, ignored files (.env, node_modules, builds) and all: its agents pause, and unarchiving
    /// finds everything where it was. A project keeps at least one desk.
    func archive(_ w: Worktree, _ r: Repo) throws {
        if isMain(w, r), try store.worktrees(repo: r.id).filter({ isMain($0, r) && !$0.archived }).count < 2 {
            throw RPCError.invalidParams("A project keeps at least one workspace.")
        }
        try pauseSessions(of: w.id)
        try store.update(Worktree.self, w.id) { $0.archived = true }
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
