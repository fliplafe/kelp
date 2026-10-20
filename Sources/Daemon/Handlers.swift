import Foundation
import Core
import GitKit
import Agents

extension JSONValue {
    func req(_ k: String) throws -> String {
        guard let s = self[k]?.string else { throw RPCError.invalidParams("missing \(k)") }
        return s
    }
}

/// A method declared in Core (`RPCMethod`) that the daemon answers: params decoded, result encoded, run through `offload`.
protocol Handled: RPCMethod {
    func handle(_ d: Daemon) throws -> Result
}

extension Handled {
    static func run(_ p: JSONValue, _ d: Daemon) throws -> JSONValue {
        let m: Self
        do { m = try (p == .null ? .object([:]) : p).decode(Self.self) }
        catch DecodingError.keyNotFound(let k, _) { throw RPCError.invalidParams("missing \(k.stringValue)") }
        catch { throw RPCError.invalidParams("\(name): \(error)") }
        return try .from(m.handle(d))
    }
}

extension Daemon {
    /// Checked before the hand-written methods; the old way stays for what isn't declared yet.
    static let typed = Dictionary(uniqueKeysWithValues: ([DaemonInfo.self, StateGet.self, StateSet.self, SessionRename.self, SessionContextWindow.self,
                                                          WorktreeNote.self, RepoWorktreeSizes.self, RepoRemoveWorktrees.self,
                                                          GitDiscardHunk.self, RemoteListFolders.self, SessionReport.self] as [any Handled.Type]).map { ($0.name, $0) })

    func handle(_ method: String, _ p: JSONValue, conn: Int) async throws -> JSONValue {
        if Self.debugWake { lock.withLock { lastMethod = method } }
        if let e = extra[method] { return try await e(self, p) }
        do {
            if let t = Self.typed[method] { return try await offload { [self] in try t.run(p, self) } }
            if let r = try await handleAsync(method, p, conn: conn) { return r }
            if method == "repo.clone" || method == "repo.cloneCancel" || method == "repo.create", let r = try await handleNewRepo(method, p, conn: conn) { return r }
            if method.hasPrefix("usage.") || method.hasPrefix("history."), let r = try await offload({ [self] in try handleHistory(method, p) }) { return r }
            if ["github.", "linear.", "jira.", "bitbucket.", "ci."].contains(where: method.hasPrefix) || method == "task.fromIssue",
               let r = try await handleIntegration(method, p, conn: conn) { return r }
            return try await offload { [self] in
                if let r = try handleAgents(method, p, conn: conn) { return r }
                if method.hasPrefix("scripts."), let r = try handleScripts(method, p, conn: conn) { return r }
                if method == "repo.addRemote" || method == "files.readRemote", let r = try handleRemote(method, p, conn: conn) { return r }
                return try handleSync(method, p, conn: conn)
            }
        }
        catch let e as GitError { throw RPCError.internalError(e.message) }
    }

    /// git, gh and ssh hold their thread until they exit, and Swift's cooperative pool has one thread per core: a few slow
    /// ones (the sidebar asks every folder's PR at once) would stall every other request, a terminal's attach included.
    /// GCD adds threads when its own are blocked.
    func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in DispatchQueue.global().async { c.resume(with: Result(catching: work)) } }
    }

    func handleSync(_ method: String, _ p: JSONValue, conn: Int) throws -> JSONValue {
        if method.hasPrefix("git."), let r = try handleGit(method, p) { return r }
        if let r = try handleSettings(method, p) ?? handleUI(method, p, conn: conn) { return r }
        switch method {
        case "ping": return "pong"
        case "daemon.shutdown":
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.stop(); exit(0) }
            return .null

        // MARK: repos
        case "repo.add":
            // A remote project's own folder: it is the project (git there would answer with the host's path).
            let path: String = try p.req("path")
            if let r = try store.repos().first(where: { $0.path == path && RemoteHost.of($0.path) != nil }) { return try .from(r) }
            // An empty folder outside any repository (New Folder in Add Project's panel) is a new project, as repo.create makes.
            if (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true, (try? Git.root(of: path)) == nil {
                try Git.run(["init", "-q"], cwd: path)
            }
            let root = try Git.root(of: path)
            if let r = try store.repos().first(where: { $0.path == root }) { return try .from(r) }
            let r = Repo(name: p["name"]?.string ?? (root as NSString).lastPathComponent, path: root, baseBranch: Git.defaultBranch(repo: root))
            try store.save(r); try syncMainWorkspaces(); notify("event.changed", "repo")
            return try .from(r)
        case "repo.list": return try .from(store.repos())
        case "scratch.ensure":   // → the scratch project's workspace (made, with its own git repo, the first time)
            let dir = root.appendingPathComponent("scratch")
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                try Paths.ensure(dir); try Git.run(["init", "-q"], cwd: dir.path)
            }
            let path = try Git.root(of: dir.path)
            var r = try store.repos().first { $0.path == path }
            if r == nil { let n = Repo(name: "Scratch", path: path, baseBranch: Git.defaultBranch(repo: path)); try store.save(n); try syncMainWorkspaces(); r = n }
            guard let repo = r, let w = try store.worktrees(repo: repo.id).first(where: { !$0.archived }) else { throw RPCError.internalError("no scratch workspace") }
            notify("event.changed", "repo")
            return try .from(w)
        case "repo.relocate":   // the project's folder moved: point it (and its desks) at the new place
            guard var r = try store.repo(p.req("id")) else { throw RPCError.invalidParams("no repo") }
            let root = try Git.root(of: p.req("path")), old = r.path
            r.path = root; try store.save(r)
            for var w in try store.worktrees(repo: r.id) where w.path == old { w.path = root; try store.save(w) }
            notify("event.changed", "repo"); return try .from(r)
        case "repo.remove":   // its workspaces go with it, and so do their agents: none keeps working out of sight
            guard let r = try store.repo(p.req("id")) else { throw RPCError.invalidParams("no repo") }
            let desks = Set(try store.worktrees(repo: r.id).map(\.id))
            for s in try store.sessions() where desks.contains(s.worktreeId ?? "") { discard(s) }
            try store.delete(r); notify("event.changed", "repo"); return .null

        // MARK: worktrees
        case "workspace.create":
            guard let r = try store.repo(p.req("repoId")) else { throw RPCError.invalidParams("no repo") }
            return try .from(createDesk(in: r))
        case "worktree.create":
            guard let r = try store.repo(p.req("repoId")) else { throw RPCError.invalidParams("no repo") }
            let auto = try nextWorkspace(in: r)
            let branch = p["branch"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? auto.branch
            let base = p["base"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? r.baseBranch
            let path = try Git.addWorktree(repo: r.path, branch: branch, base: base,
                                           into: root.appendingPathComponent("worktrees/\(r.name)"), copyFiles: r.copyFiles)
            let w = Worktree(repoId: r.id, branch: branch, path: path, note: p["note"]?.string ?? (p["branch"] == nil ? auto.name : ""), base: base)
            try store.save(w)
            var result = try JSONValue.from(w)
            let cfg = RepoConfig.load(repoPath: r.path)
            // Everything .kelp.yaml does waits for the user's trust in this version of the file, not only `setup`: `tabs`
            // starts agents and `shared` links folders, and a freshly cloned repository wrote that file, not the user.
            let trustedConfig = trusted(repoPath: r.path)
            if trustedConfig {
                Git.linkShared(cfg.shared, repo: r.path, worktree: path)
                if p["tabs"]?.bool != false { for t in cfg.tabs { _ = try? spawn(cwd: path, manifest: manifest(t, command: nil), worktreeId: w.id) } }
            }
            let asks = cfg.setup != nil || !cfg.tabs.isEmpty || !cfg.shared.isEmpty
            if asks, p["setup"]?.bool != false, !trustedConfig, case .object(var o) = result {
                o["setupNeedsTrust"] = true; result = .object(o)   // the app asks, then scripts.trust + scripts.run "setup"
            } else if let setup = cfg.setup, p["setup"]?.bool != false {
                var o = Launch(); o.title = "setup"
                let s = try spawn(cwd: path, manifest: .custom(setup), worktreeId: w.id, o)
                if case .object(var o) = result { o["setupSession"] = .string(s.id); result = .object(o) }
            }
            notify("event.changed", "worktree")
            return result
        case "worktree.list":
            try syncMainWorkspaces()
            return try .from(store.worktrees(repo: p["repoId"]?.string).filter { p["archived"]?.bool == true || !$0.archived })
        case "worktree.archive", "worktree.remove":
            guard var w = try store.worktree(p.req("id")), let r = try store.repo(w.repoId) else { throw RPCError.invalidParams("no worktree") }
            if isMain(w, r) {
                if method == "worktree.archive" { try archiveDesk(w, r) } else { try removeDesk(w, r) }
                return .null
            }
            let remove = method == "worktree.remove"
            if FileManager.default.fileExists(atPath: w.path) {
                try Git.removeWorktree(repo: r.path, path: w.path, branch: remove ? w.branch : nil, force: p["force"]?.bool == true,
                                       dropCommits: p["dropCommits"]?.bool == true)
            }
            for s in (try store.sessions()) where s.worktreeId == w.id { if remove { discard(s) } else { existing(s.id)?.pty.kill() } }
            if remove { try store.delete(w) } else { w.archived = true; try store.save(w) }
            notify("event.changed", "worktree"); return .null
        case "worktree.unarchive":
            guard var w = try store.worktree(p.req("id")) else { throw RPCError.invalidParams("no worktree") }
            w.archived = false; try store.save(w); notify("event.changed", "worktree"); return .null
        case "worktree.unmerged":   // {id} → commits on its branch that no other branch or remote has (lost if it's deleted)
            let w = try cwd(forWorktree: p.req("id"))
            guard let r = try store.repo(w.repoId), Git.branchExists(r.path, w.branch) else { return .int(0) }
            return .int(try Git.onlyOnBranch(repo: r.path, w.branch))
        case "worktree.dirty":
            return .bool(try Git.isDirty(cwd(forWorktree: p.req("id")).path))

        // MARK: sessions
        case "session.create":
            // cwd wins when both are given (e.g. an agent building an extension, shown in the current workspace).
            var dir = p["cwd"]?.string.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }; let wid = p["worktreeId"]?.string
            if let wid, dir == nil { dir = try cwd(forWorktree: wid).path }
            guard let dir else { throw RPCError.invalidParams("cwd or worktreeId required") }
            let m = try manifest(p["agent"]?.string, command: p["command"]?.string)
            return try .from(spawn(cwd: dir, manifest: m, worktreeId: wid, Launch(p)))
        case "session.list":
            let live = try store.sessions().map { s -> Session in existing(s.id)?.snapshot ?? s }
            return try .from(live.filter { p["worktreeId"]?.string == nil || $0.worktreeId == p["worktreeId"]?.string })
        case "session.attach":
            let id = try p.req("id")
            if existing(id) == nil, try store.session(id)?.status == .exited {   // ended: what it last printed, from its log
                return .obj(["history": .string(TerminalReplies.withoutQueries(try liveSessionOrLog(id, bytes: LiveSession.ringLimit)).base64EncodedString())])
            }
            // Showing a tab isn't reading it: the app marks it read once it was looked at (or typed into).
            return .obj(["history": .string(try liveSession(id).attach(conn).base64EncodedString())])
        case "session.detach": existing(try p.req("id"))?.detach(conn); return .null
        case "session.write":
            let s = try liveSession(p.req("id"))
            if let b = p["base64"]?.string, let d = Data(base64Encoded: b) { s.userInput(d) }
            else { s.pty.write(Data(try p.req("text").utf8)) }
            return .null
        case "session.send":   // text, then Enter after a beat so TUIs treat it as a submit, not a paste
            try liveSession(p.req("id")).send(p.req("text"), enter: p["enter"]?.bool != false)
            return .null
        case "session.resize":
            let (cols, rows) = Launch.size(p)
            try liveSession(p.req("id")).resize(cols: cols, rows: rows); return .null
        case "session.kill":
            if let ls = lock.withLock({ live[(p["id"]?.string ?? "")] }) { ls.pty.kill() }
            else if var s = try store.session(p.req("id")), s.status == .hibernated { s.status = .exited; publish(s) }   // don't wake just to kill
            return .null
        case "session.choose":   // {id, answer: allow | deny} → false when no menu is on screen to answer
            guard let s = existing(try p.req("id"))?.choose(try p.req("answer")) else { return .bool(false) }
            publish(s); return .bool(true)
        case "agent.setSecret":   // {agent, key, value}: kept in the login keychain by the daemon, which reads it at launch
            let account = AgentManifest.secretAccount(agent: try p.req("agent"), key: try p.req("key"))
            if let v = p["value"]?.string, !v.isEmpty { try Keychain.set(v, account: account) } else { Keychain.delete(account) }
            return .null
        case "ports.list": return try .from(ports(worktree: p.req("worktreeId")))   // {worktreeId} → servers its sessions run
        case "session.usage": return try .from(usage())   // → [{session, cpu, memory, processes}], busiest first
        case "ports.stop":   // {worktreeId, pid}: only a process one of the workspace's sessions started
            let pid = Int32(clamping: p["pid"]?.int ?? 0)
            guard pid > 0, ports(worktree: try p.req("worktreeId")).contains(where: { $0.pid == pid }) else { throw RPCError.invalidParams("That process isn't running in this workspace.") }
            kill(pid, SIGTERM); return .null
        case "session.busy":   // a shell running something in the foreground: closing it would stop that program
            return existing(try p.req("id"))?.pty.foregroundProgram.map { .string($0) } ?? .null
        case "session.read":
            let d = try liveSessionOrLog(p.req("id"), bytes: p["bytes"]?.int ?? 8192)
            // swiftlint:disable:next optional_data_string_conversion
            return .string(StatusDetector.stripANSI(String(decoding: d, as: UTF8.self)))   // lossy on purpose: windows cut UTF-8
        case "session.markUnread":
            if let r = existing(try p.req("id"))?.markUnread() { try store.save(r); notify("event.session", try .from(r)) }
            return .null
        case "session.markRead":
            if let r = existing(try p.req("id"))?.markRead() { try store.save(r); notify("event.session", try .from(r)) }
            return .null
        case "session.hook":   // from a running agent; a late one (it was paused or ended since) wakes nothing
            guard let ls = existing(try p.req("id")) else { return .null }
            if let t = p["transcript"]?.string, !t.isEmpty { ls.transcriptPath = t }
            if let dir = p["cwd"]?.string, let s = ls.workIn(dir) { publish(s) }
            if let n = p["notification"], Hooks.isIdleReminder(n) { return .null }
            let event: String = try p.req("event")
            ls.hook(event == "done" && Hooks.hasBackgroundWork(p) ? "working" : event,
                    trigger: p["trigger"]?.string, message: p["notification"]?["message"]?.string); return .null
        case "session.turn":   // the agent's last turn: files it changed and how long it took (nil before its first turn ends)
            guard let ls = existing(try p.req("id")) else { return .null }
            return .obj(["turn": ls.lastTurn.flatMap { try? JSONValue.from($0) } ?? .null, "hasBase": .bool(ls.turnBase != nil)])
        case "session.lastReply":   // the agent's last message, from its transcript (Claude Code), for summaries
            guard let t = existing(try p.req("id")).flatMap(transcript(of:)) else { return .null }
            return Self.lastReply(transcript: t).map { .string($0) } ?? .null

        // MARK: git
        case "git.status": return try .from(Git.status(cwd(forWorktree: p.req("id")).path))
        case "git.diff":
            let w = try cwd(forWorktree: p.req("id"))
            let src: DiffSource
            var dir = w.path
            switch p["source"]?.string ?? "all" {
            case "turn":   // since the agent's last turn started, where it worked then (its own worktree, maybe)
                guard let ls = existing(try p.req("session")), let base = ls.turnBase else { throw RPCError.invalidParams("That agent hasn't started a turn since Kelp launched.") }
                src = .since(tree: base); dir = ls.turnDir ?? dir
            case "unstaged": src = .unstaged
            case "staged": src = .staged
            case "branch":
                let base = try store.repo(w.repoId)?.baseBranch ?? "main"
                src = .branch(base: p["base"]?.string ?? base)
            case "commit": src = .commit(try p.req("commit"))
            default: src = .allUncommitted
            }
            return try .from(Git.diff(dir, source: src, file: p["file"]?.string))
        case "git.log":
            let w = try cwd(forWorktree: p.req("id"))
            let base = try store.repo(w.repoId)?.baseBranch
            return .array(try Git.log(w.path, base: p["all"]?.bool == true ? nil : base).map { .obj(["hash": .string($0.hash), "subject": .string($0.subject)]) })
        case "git.stage", "git.unstage":
            let w = try cwd(forWorktree: p.req("id"))
            let files = (p["files"]?.array ?? []).compactMap(\.string)
            if method == "git.stage" { try Git.stage(w.path, files: files) } else { try Git.unstage(w.path, files: files) }
            return .null
        case "git.hunk":   // stage/unstage one hunk: {id, file, hunk, reverse, header?}; with its "@@" header, that hunk or none
            let w = try cwd(forWorktree: p.req("id")); let file = try p.req("file")
            let rev = p["reverse"]?.bool == true, header = p["header"]?.string
            let d = try Git.diff(w.path, source: rev ? .staged : .unstaged, file: file).first
            let i = header.map { h in d?.hunks.firstIndex { $0.header == h } ?? -1 } ?? p["hunk"]?.int ?? -1
            guard let d, d.hunks.indices.contains(i) else {
                throw RPCError.invalidParams(rev ? "The file changed since it was shown; nothing was unstaged." : "The file changed since it was shown; nothing was staged.")
            }
            try Git.applyHunk(w.path, diff: d, hunk: i, reverse: rev); return .null
        case "git.commit":
            return .string(try Git.commit(cwd(forWorktree: p.req("id")).path, message: p.req("message"), all: p["all"]?.bool == true,
                                          amend: p["amend"]?.bool == true))
        case "git.push":   // the branch checked out now (a workspace's record can be stale after a switch)
            try Git.remote(cwd(forWorktree: p.req("id")).path, .push); return .null
        case "git.merge":   // merge worktree branch into the repo's base branch (main checkout)
            let w = try cwd(forWorktree: p.req("id"))
            guard let r = try store.repo(w.repoId) else { throw RPCError.invalidParams("no repo") }
            if try Git.isDirty(w.path) { throw RPCError.invalidParams("worktree has uncommitted changes") }
            // The branch checked out in the desk now (a switch makes the record stale), into the base and only the base.
            let branch = (try? Git.currentBranch(w.path)) ?? w.branch
            let res = try Git.merge(branch: branch, into: r.path, onto: r.baseBranch, keepConflicts: p["keepConflicts"]?.bool == true)
            return .obj(["merged": .bool(res.merged), "conflicts": .array(res.conflicts.map { .string($0) })])

        // MARK: files
        case "files.list": return try .from(ProjectFiles.list(cwd(forWorktree: p.req("id")).path))
        case "files.search":
            return try .from(ProjectFiles.search(cwd(forWorktree: p.req("id")).path, query: p.req("query"),
                                                 regex: p["regex"]?.bool == true, caseSensitive: p["case"]?.bool == true))

        // MARK: review comments
        case "comment.add":
            let c = DiffComment(worktreeId: try p.req("id"), file: try p.req("file"), startLine: p["start"]?.int ?? 1,
                                endLine: p["end"]?.int ?? p["start"]?.int ?? 1, quote: p["quote"]?.string ?? "", text: try p.req("text"))
            try store.save(c); return try .from(c)
        case "comment.list": return try .from(store.comments(worktree: p.req("id")))
        case "comment.setState":
            guard var c = try store.db.read({ try DiffComment.fetchOne($0, key: p.req("id")) }) else { throw RPCError.invalidParams("no comment") }
            c.state = DiffComment.State(rawValue: try p.req("state")) ?? .open; try store.save(c); return .null
        case "comment.send":   // all open comments -> one message into the agent's terminal
            let w = try cwd(forWorktree: p.req("id"))
            let open = try store.comments(worktree: w.id).filter { $0.state == .open }
            guard !open.isEmpty else { return .int(0) }
            try handleSync("session.send", .obj(["id": .string(try p.req("session")), "text": .string(ReviewMessage.compose(branch: w.branch, comments: open))]), conn: conn)
            for var c in open { c.state = .sent; try store.save(c) }
            return .int(open.count)

        default: throw RPCError.methodNotFound
        }
    }
}

extension DaemonInfo: Handled {
    func handle(_ d: Daemon) throws -> Result {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return Result(path: exe.resolvingSymlinksInPath().path, binaryMTime: Daemon.binaryMTime, pid: Int(getpid()),
                      liveSessions: d.lock.withLock { d.live.values.filter { $0.snapshot.status != .exited }.count })
    }
}

extension GitDiscardHunk: Handled {
    func handle(_ d: Daemon) throws -> Done {
        let w = try d.cwd(forWorktree: id)
        guard let diff = try Git.diff(w.path, source: .unstaged, file: file).first, diff.hunks.indices.contains(hunk),
              diff.hunks[hunk].header == header else {
            throw RPCError.invalidParams("The file changed since it was shown; nothing was discarded.")
        }
        try Git.discardHunk(w.path, diff: diff, hunk: hunk); return Done()
    }
}

extension WorktreeNote: Handled {
    func handle(_ d: Daemon) throws -> Done {
        guard var w = try d.store.worktree(id) else { throw RPCError.invalidParams("no worktree") }
        w.note = note; try d.store.save(w); d.notify("event.changed", "worktree"); return Done()
    }
}

extension RepoWorktreeSizes: Handled {
    func handle(_ d: Daemon) throws -> [Item] {
        guard let r = try d.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        guard RemoteHost.of(r.path) == nil else { return [] }   // their disk is on the host
        let workspaces = try Self.workspaces(d, r)
        return try Git.linkedWorktrees(r.path).filter { FileManager.default.fileExists(atPath: $0.path) }.map { w in
            Item(path: w.path, bytes: Self.du(w.path),
                 removable: !w.locked && !workspaces.contains(Self.real(w.path)) && (try? Git.isDirty(w.path)) == false)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Kelp's own worktree workspaces (from older versions): git prints real paths, the store keeps them as created.
    static func workspaces(_ d: Daemon, _ r: Repo) throws -> Set<String> { Set(try d.store.worktrees(repo: r.id).map { real($0.path) }) }
    static func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }

    /// Blocks on disk as `du` counts them (16 GB of build products: about a second); unreadable files leave out only themselves.
    static func du(_ path: String) -> Int {
        let out = (try? Git.run(["-sk", path], cwd: path, executable: "/usr/bin/du", ok: [0, 1])) ?? ""
        return (Int(out.prefix { $0.isNumber }) ?? 0) * 1024
    }
}

extension RepoRemoveWorktrees: Handled {
    func handle(_ d: Daemon) throws -> Result {
        guard let r = try d.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        let linked = try Git.linkedWorktrees(r.path), workspaces = try RepoWorktreeSizes.workspaces(d, r)
        var out = Result(removed: [], kept: [:])
        for p in paths {
            guard let w = linked.first(where: { $0.path == p }), !workspaces.contains(RepoWorktreeSizes.real(p)) else {
                out.kept[p] = "Not one of the project's other worktrees."; continue
            }
            do {
                try Git.run(["worktree", "remove", p], cwd: r.path)   // no --force: git keeps one with changes, untracked files or a lock
                if let b = w.branch { _ = try? Git.run(["branch", "-d", b], cwd: r.path) }   // -d: only if its commits are on another branch
                out.removed.append(p)
            } catch let e as GitError { out.kept[p] = e.message }
        }
        return out
    }
}

extension SessionReport: Handled {
    func handle(_ d: Daemon) throws -> Done {
        guard ProgramStatus.states.contains(state) else { throw RPCError.invalidParams("state is one of idle, working, blocked, done, error, clear") }
        guard let ls = d.existing(id) else { return Done() }   // ended or paused: there's nothing to show it on
        let r = ProgramStatus.Report(state: state, kind: state == "blocked" ? kind : nil, msg: message,
                                     progress: state == "working" ? progress.map { min(100, max(0, $0)) } : nil)
        if let s = ls.report(r) { d.publish(s) }
        return Done()
    }
}

extension SessionContextWindow: Handled {
    func handle(_ d: Daemon) throws -> Usage? {
        guard let t = d.existing(id).flatMap(d.transcript(of:)), let c = Daemon.contextUsage(transcript: t) else { return nil }
        return Usage(used: c.used, window: d.contextWindow(model: c.model, peak: c.peak))
    }
}

extension Daemon {
    /// Tokens in the context of a Claude Code conversation: the last reply's input (with cache) plus its output, or what a
    /// newer compaction left. `peak` is the most it held (a compaction's starting size counts), for telling the window.
    static func contextUsage(transcript url: URL) -> (used: Int, peak: Int, model: String)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 1 << 20 ? size - (1 << 20) : 0)   // a turn's tool results can be hundreds of KB
        guard let data = try? h.readToEnd() else { return nil }
        var compacted: (pre: Int, post: Int)?
        for line in data.split(separator: 0x0A).reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["isSidechain"] as? Bool != true else { continue }
            if compacted == nil, o["subtype"] as? String == "compact_boundary" {
                // Without postTokens (older Claude Code) what's left is unknown until the next reply.
                guard let m = o["compactMetadata"] as? [String: Any], let post = m["postTokens"] as? Int else { return nil }
                compacted = (m["preTokens"] as? Int ?? 0, post); continue
            }
            guard o["type"] as? String == "assistant", let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { continue }
            let used = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"].reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
            guard used > 0 else { continue }   // API errors and other synthetic replies carry no usage
            return (compacted?.post ?? used, max(used, compacted?.pre ?? 0), m["model"] as? String ?? "")
        }
        return compacted.map { ($0.post, $0.pre, "") }
    }

    /// The text of the last assistant message in a Claude Code transcript (read from the file's tail).
    static func lastReply(transcript url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? h.readToEnd() else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["type"] as? String == "assistant",
                  let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(4000)) }
        }
        return nil
    }
}
