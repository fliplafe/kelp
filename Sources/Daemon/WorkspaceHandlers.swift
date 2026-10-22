import Foundation
import Core
import GitKit
import Agents

// Projects and their workspaces.

extension RepoAdd: Handled {
    func handle(_ d: Daemon) throws -> Repo {
        // A remote project's own folder: it is the project (git there would answer with the host's path).
        if let r = try d.store.repos().first(where: { $0.path == path && RemoteHost.of($0.path) != nil }) { return r }
        // An empty folder outside any repository (New Folder in Add Project's panel) is a new project: `git init` there.
        if (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true, (try? Git.root(of: path)) == nil {
            try Git.run(["init", "-q"], cwd: path)
        }
        let root = try Git.root(of: path)
        if let r = try d.store.repos().first(where: { $0.path == root }) { return r }
        let r = Repo(name: name ?? (root as NSString).lastPathComponent, path: root, baseBranch: Git.defaultBranch(repo: root))
        try d.store.save(r); try d.workspaces.syncMainWorkspaces(); d.notify(ChangedEvent.repo)
        return r
    }
}

extension RepoList: Handled { func handle(_ d: Daemon) throws -> [Repo] { try d.store.repos() } }

extension ScratchEnsure: Handled {
    func handle(_ d: Daemon) throws -> Worktree {
        let dir = d.root.appendingPathComponent("scratch")
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            try Paths.ensure(dir); try Git.run(["init", "-q"], cwd: dir.path)
        }
        let path = try Git.root(of: dir.path)
        var r = try d.store.repos().first { $0.path == path }
        if r == nil {
            let n = Repo(name: "Scratch", path: path, baseBranch: Git.defaultBranch(repo: path))
            try d.store.save(n); try d.workspaces.syncMainWorkspaces(); r = n
        }
        guard let repo = r, let w = try d.store.worktrees(repo: repo.id).first(where: { !$0.archived }) else {
            throw RPCError.internalError("no scratch workspace")
        }
        d.notify(ChangedEvent.repo)
        return w
    }
}

extension RepoRelocate: Handled {
    func handle(_ d: Daemon) throws -> Repo {
        guard var r = try d.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        let root = try Git.root(of: path), old = r.path
        r.path = root; try d.store.save(r)
        for w in try d.store.worktrees(repo: r.id) where w.path == old { try d.store.update(Worktree.self, w.id) { $0.path = root } }
        d.notify(ChangedEvent.repo)
        return r
    }
}

/// Its workspaces go with it, and so do their agents: none keeps working out of sight.
extension RepoRemove: Handled {
    func handle(_ d: Daemon) throws -> Done {
        guard let r = try d.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        let desks = Set(try d.store.worktrees(repo: r.id).map(\.id))
        for s in try d.store.sessions() where desks.contains(s.worktreeId ?? "") { d.sessions.discard(s) }
        try d.store.delete(r); d.notify(ChangedEvent.repo)
        return Done()
    }
}

extension WorkspaceCreate: Handled {
    func handle(_ d: Daemon) throws -> Worktree {
        guard let r = try d.store.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        return try d.workspaces.createDesk(in: r)
    }
}

extension WorktreeCreate: Handled {
    func handle(_ d: Daemon) throws -> Result {
        guard let r = try d.store.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        let auto = try d.workspaces.nextWorkspace(in: r)
        let branch = try d.ref(branch.flatMap { $0.isEmpty ? nil : $0 }) ?? auto.branch
        let base = try d.ref(base.flatMap { $0.isEmpty ? nil : $0 }) ?? r.baseBranch
        let path = try Git.addWorktree(repo: r.path, branch: branch, base: base, into: Daemon.worktreesDir(d.root, r), copyFiles: r.copyFiles)
        let w = Worktree(repoId: r.id, branch: branch, path: path, note: note ?? (self.branch == nil ? auto.name : ""), base: base)
        try d.store.save(w)
        var result = Result(worktree: w)
        // Everything .kelp.yaml does waits for the user's trust in this version of the file, not only `setup`: `tabs`
        // starts agents and `shared` links folders, and a freshly cloned repository wrote that file, not the user.
        // Checked and used from one read.
        let read = d.workspaces.configAndTrust(r.path), cfg = read.config
        if read.trusted {
            Git.linkShared(cfg.shared, repo: r.path, worktree: path)
            if tabs != false {
                for t in cfg.tabs {
                    do { _ = try d.sessions.spawn(cwd: path, manifest: d.sessions.manifest(t, command: nil), worktreeId: w.id) }
                    catch { Log.session.error(".kelp.yaml tab \(t, privacy: .public) didn't start: \(error)") }
                }
            }
        }
        let asks = cfg.setup != nil || !cfg.tabs.isEmpty || !cfg.shared.isEmpty
        if asks, setup != false, !read.trusted {
            result.setupNeedsTrust = true   // the app asks, then scripts.trust + scripts.run "setup"
        } else if let cmd = cfg.setup, setup != false {
            var o = Sessions.Launch(); o.title = "setup"
            let s = try d.sessions.spawn(cwd: path, manifest: .custom(cmd), worktreeId: w.id, o)
            result.setupSession = s.id
        }
        d.notify(ChangedEvent.worktree)
        return result
    }
}

/// Only reads: desks follow their folders' branches as they change (`watchHeads`), not when someone lists them.
extension WorktreeList: Handled {
    func handle(_ d: Daemon) throws -> [Worktree] { try d.store.worktrees(repo: repoId).filter { archived == true || !$0.archived } }
}

extension WorktreeArchive: Handled {
    func handle(_ d: Daemon) throws -> Done {
        guard let w = try d.store.worktree(id), let r = try d.store.repo(w.repoId) else { throw RPCError.invalidParams("no worktree") }
        try d.archive(w, r); return Done()
    }
}

extension WorktreeRemove: Handled {
    func handle(_ d: Daemon) throws -> Done {
        guard let w = try d.store.worktree(id), let r = try d.store.repo(w.repoId) else { throw RPCError.invalidParams("no worktree") }
        if d.workspaces.isMain(w, r) { try d.removeDesk(w, r); return Done() }
        let force = force == true, drop = dropCommits == true
        if FileManager.default.fileExists(atPath: w.path) {
            // Refuse before anything stops; then stop its agents and only then remove, checking again: an agent still
            // writing can't have its work deleted under it.
            try Git.checkRemovable(repo: r.path, path: w.path, branch: w.branch, force: force, dropCommits: drop)
            try d.sessions.pauseSessions(of: w.id)
            try Git.removeWorktree(repo: r.path, path: w.path, branch: w.branch, force: force, dropCommits: drop)
        } else {
            try d.sessions.pauseSessions(of: w.id)
        }
        for s in try d.store.sessions() where s.worktreeId == w.id { d.sessions.discard(s) }
        try d.store.delete(w)
        d.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension WorktreeUnarchive: Handled {
    func handle(_ d: Daemon) throws -> Done {
        guard try d.store.update(Worktree.self, id, { $0.archived = false }) != nil else { throw RPCError.invalidParams("no worktree") }
        d.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension WorktreeUnmerged: Handled {
    func handle(_ d: Daemon) throws -> Int {
        let w = try d.cwd(forWorktree: id)
        guard let r = try d.store.repo(w.repoId), Git.branchExists(r.path, w.branch) else { return 0 }
        return try Git.onlyOnBranch(repo: r.path, w.branch)
    }
}

extension WorktreeDirty: Handled { func handle(_ d: Daemon) throws -> Bool { try Git.isDirty(d.cwd(forWorktree: id).path) } }

extension Daemon {
    /// Archiving keeps the folder, ignored files (.env, node_modules, builds) and all: its agents pause, and unarchiving
    /// finds everything where it was. A project keeps at least one desk.
    func archive(_ w: Worktree, _ r: Repo) throws {
        if workspaces.isMain(w, r), try store.worktrees(repo: r.id).filter({ workspaces.isMain($0, r) && !$0.archived }).count < 2 {
            throw RPCError.invalidParams("A project keeps at least one workspace.")
        }
        try sessions.pauseSessions(of: w.id)
        try store.update(Worktree.self, w.id) { $0.archived = true }
        notify(ChangedEvent.worktree)
    }

    func removeDesk(_ w: Worktree, _ r: Repo) throws {
        guard try store.worktrees(repo: r.id).filter({ workspaces.isMain($0, r) }).count > 1 else {
            throw RPCError.invalidParams("A project keeps at least one workspace; remove the project instead.")
        }
        for s in try store.sessions() where s.worktreeId == w.id { sessions.discard(s) }
        try store.delete(w)
        notify(ChangedEvent.worktree)
    }

    static let workspaceMethods: [any Handled.Type] = [RepoAdd.self, RepoList.self, ScratchEnsure.self, RepoRelocate.self, RepoRemove.self,
        WorkspaceCreate.self, WorktreeCreate.self, WorktreeList.self, WorktreeArchive.self, WorktreeRemove.self, WorktreeUnarchive.self,
        WorktreeUnmerged.self, WorktreeDirty.self]
}
