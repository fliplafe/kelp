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
        try d.store.save(r); try d.syncMainWorkspaces(); d.notify(ChangedEvent.repo)
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
            try d.store.save(n); try d.syncMainWorkspaces(); r = n
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
        for s in try d.store.sessions() where desks.contains(s.worktreeId ?? "") { d.discard(s) }
        try d.store.delete(r); d.notify(ChangedEvent.repo)
        return Done()
    }
}

extension WorkspaceCreate: Handled {
    func handle(_ d: Daemon) throws -> Worktree {
        guard let r = try d.store.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        return try d.createDesk(in: r)
    }
}

extension WorktreeCreate: Handled {
    func handle(_ d: Daemon) throws -> Result {
        guard let r = try d.store.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        let auto = try d.nextWorkspace(in: r)
        let branch = try d.ref(branch.flatMap { $0.isEmpty ? nil : $0 }) ?? auto.branch
        let base = try d.ref(base.flatMap { $0.isEmpty ? nil : $0 }) ?? r.baseBranch
        let path = try Git.addWorktree(repo: r.path, branch: branch, base: base, into: Daemon.worktreesDir(d.root, r), copyFiles: r.copyFiles)
        let w = Worktree(repoId: r.id, branch: branch, path: path, note: note ?? (self.branch == nil ? auto.name : ""), base: base)
        try d.store.save(w)
        var result = Result(worktree: w)
        // Everything .kelp.yaml does waits for the user's trust in this version of the file, not only `setup`: `tabs`
        // starts agents and `shared` links folders, and a freshly cloned repository wrote that file, not the user.
        // Checked and used from one read.
        let read = d.configAndTrust(r.path), cfg = read.config
        if read.trusted {
            Git.linkShared(cfg.shared, repo: r.path, worktree: path)
            if tabs != false {
                for t in cfg.tabs {
                    do { _ = try d.spawn(cwd: path, manifest: d.manifest(t, command: nil), worktreeId: w.id) }
                    catch { Log.session.error(".kelp.yaml tab \(t, privacy: .public) didn't start: \(error)") }
                }
            }
        }
        let asks = cfg.setup != nil || !cfg.tabs.isEmpty || !cfg.shared.isEmpty
        if asks, setup != false, !read.trusted {
            result.setupNeedsTrust = true   // the app asks, then scripts.trust + scripts.run "setup"
        } else if let cmd = cfg.setup, setup != false {
            var o = Daemon.Launch(); o.title = "setup"
            let s = try d.spawn(cwd: path, manifest: .custom(cmd), worktreeId: w.id, o)
            result.setupSession = s.id
        }
        d.notify(ChangedEvent.worktree)
        return result
    }
}

extension WorktreeList: Handled {
    func handle(_ d: Daemon) throws -> [Worktree] {
        try d.syncMainWorkspaces()
        return try d.store.worktrees(repo: repoId).filter { archived == true || !$0.archived }
    }
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
        if d.isMain(w, r) { try d.removeDesk(w, r); return Done() }
        let force = force == true, drop = dropCommits == true
        if FileManager.default.fileExists(atPath: w.path) {
            // Refuse before anything stops; then stop its agents and only then remove, checking again: an agent still
            // writing can't have its work deleted under it.
            try Git.checkRemovable(repo: r.path, path: w.path, branch: w.branch, force: force, dropCommits: drop)
            try d.pauseSessions(of: w.id)
            try Git.removeWorktree(repo: r.path, path: w.path, branch: w.branch, force: force, dropCommits: drop)
        } else {
            try d.pauseSessions(of: w.id)
        }
        for s in try d.store.sessions() where s.worktreeId == w.id { d.discard(s) }
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
    static let workspaceMethods: [any Handled.Type] = [RepoAdd.self, RepoList.self, ScratchEnsure.self, RepoRelocate.self, RepoRemove.self,
        WorkspaceCreate.self, WorktreeCreate.self, WorktreeList.self, WorktreeArchive.self, WorktreeRemove.self, WorktreeUnarchive.self,
        WorktreeUnmerged.self, WorktreeDirty.self]
}
