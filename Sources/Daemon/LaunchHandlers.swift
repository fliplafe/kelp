import Foundation
import Core
import GitKit
import Agents
import AgentData
import Integrations

extension Daemon.Launch {
    init(_ o: some LaunchOptions) {
        self.init()
        model = o.model; effort = o.effort; prompt = o.prompt; title = o.title; profile = o.profile
        draft = o.draft == true; openURLs = o.openURLs == true
        (cols, rows) = Self.size(cols: o.cols, rows: o.rows)
    }
}

extension SessionCreate: Handled {
    func handle(_ d: Daemon) throws -> Session {
        // cwd wins when both are given (e.g. an agent building an extension, shown in the current workspace).
        var dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        if let worktreeId, dir == nil { dir = try d.cwd(forWorktree: worktreeId).path }
        guard let dir else { throw RPCError.invalidParams("cwd or worktreeId required") }
        var o = Daemon.Launch(self)
        if let tmux {   // a terminal running tmux: the record keeps the argv that attaches again (Tmux.session)
            let name = Tmux.name(tmux)
            guard !name.isEmpty else { throw RPCError.invalidParams("Name the tmux session.") }
            o.argv = Tmux.argv(name)
            if o.title == nil { o.title = "tmux \(name)" }
        }
        return try d.spawn(cwd: dir, manifest: d.manifest(tmux == nil ? agent : "shell", command: tmux == nil ? command : nil),
                                 worktreeId: worktreeId, o)
    }
}

extension TmuxList: Handled {
    func handle(_ d: Daemon) throws -> Result {
        let w = try d.cwd(forWorktree: worktreeId)
        let list = ["list-sessions", "-F", Tmux.format]
        // On the host for a remote project, through its login shell as its terminals are (tmux is on that PATH).
        let argv = try RemoteHost.of(w.path).map { [RemoteHost.ssh] + $0.sshArgs(tty: false) + [$0.command(["tmux"] + list)] }
            ?? [LoginPath.resolve("tmux")] + list
        var env = ProcessInfo.processInfo.environment; env["PATH"] = d.childPath
        let r = try Subprocess.run(argv, cwd: NSHomeDirectory(), env: env, timeLimit: 30)
        let err = String(decoding: r.stderr, as: UTF8.self)
        if r.status == 0 { return Tmux.parse(String(decoding: r.stdout, as: UTF8.self)) }
        if Tmux.noServer(err) { return [] }
        let why = err.trimmingCharacters(in: .whitespacesAndNewlines)
        throw RPCError.invalidParams(r.timedOut ? "tmux didn't answer." : why.isEmpty ? "tmux list-sessions failed (exit code \(r.status))." : why)
    }
}

extension SessionRestart: Handled {
    func handle(_ d: Daemon) throws -> Session {
        guard try d.store.session(id) != nil else { throw RPCError.invalidParams("no session") }
        // One copy of the conversation at a time: the resumed agent starts once the old one is gone (SIGKILL after 2 s).
        // Under its wake lock, and a paused one marked ended there: a tab opening it meanwhile can't wake a second copy.
        // If the new one can't start, the old one still ends as Ended. The record is read there, as it is then (a rename
        // just before is kept, in it and in the new session's title).
        let old: Session = try d.wakeLocks.withLock(id) {
            if let ls = d.existing(id) { Daemon.waitGone(ls.pty.terminate()) }
            else { try d.store.update(Session.self, id) { if $0.status == .hibernated { $0.status = .exited } } }
            guard let s = try d.store.session(id) else { throw RPCError.invalidParams("no session") }
            return s
        }
        let m = try d.manifest(old.agent, command: nil, fallbackArgv: old.argv)
        var o = Daemon.Launch(self); o.title = old.titleManual ? old.title : nil
        if o.profile == nil { o.profile = old.profile }   // the same account unless told otherwise
        // The new session pins an id of its own, never the old one's.
        o.argv = Daemon.withoutSessionId(resume != false ? d.resumeArgv(old, m) : old.argv, flag: m.sessionIdFlag)
        let s = try d.spawn(cwd: old.cwd, manifest: m, worktreeId: old.worktreeId, o)
        d.discard(old)   // its exit, still to come, doesn't save it again
        return s
    }
}

extension SessionHandoff: Handled {
    func handle(_ d: Daemon) throws -> Session {
        guard let old = try d.store.session(id) else { throw RPCError.invalidParams("no session") }
        // The brief is a file on this Mac: an agent on a remote host couldn't read it.
        if RemoteHost.of(old.cwd) != nil { throw RPCError.invalidParams("Handoff isn't available for remote projects yet.") }
        let transcript = try d.handoffFile(old, full: full == true)
        var o = Daemon.Launch(self)
        o.prompt = "Read \(transcript.path) — the transcript of the previous agent session in this project. "
            + (prompt ?? "Continue the task where the previous agent left off.")
        o.title = (old.title.isEmpty ? (old.agent ?? "agent") : old.title) + " (handoff)"
        return try d.spawn(cwd: old.cwd, manifest: d.manifest(agent ?? old.agent, command: nil), worktreeId: old.worktreeId, o)
    }
}

extension HistoryResume: Handled {
    func handle(_ d: Daemon) throws -> Session {
        guard let s = session else { throw RPCError.invalidParams("session required") }
        var cwd = s.cwd, wid = worktreeId
        if let w = wid, let wt = try d.store.worktree(w) { cwd = wt.path } else {
            let real = URL(fileURLWithPath: s.cwd).resolvingSymlinksInPath().path
            wid = try d.store.worktrees().first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == real }?.id
        }
        guard FileManager.default.fileExists(atPath: cwd) else { throw RPCError.invalidParams("the session's folder no longer exists: \(cwd)") }
        var o = Daemon.Launch(self); o.title = s.title.isEmpty ? "Resumed \(s.agent.rawValue)" : s.title
        var m = try d.manifest(s.agent.rawValue, command: nil)
        m.args += Array(History.resumeCommand(for: s).dropFirst())
        return try d.spawn(cwd: cwd, manifest: m, worktreeId: wid, o)
    }
}

/// A late one (it was paused or ended since) wakes nothing.
extension SessionHook: Handled {
    func handle(_ d: Daemon) throws -> Done {
        guard let ls = d.existing(id) else { return Done() }
        if let transcript, !transcript.isEmpty { ls.transcriptPath = transcript }
        if let cwd, ls.workIn(cwd) != nil { d.publish(ls) }
        if let notification, Hooks.isIdleReminder(notification) { return Done() }
        guard let event else { throw RPCError.invalidParams("missing event") }
        let background = Hooks.hasBackgroundWork(.obj(["background_tasks": .array(backgroundTasks ?? [])]))
        ls.hook(event == "done" && background ? "working" : event, trigger: trigger, message: notification?["message"]?.string)
        return Done()
    }
}

extension SessionAnnotate: Handled {
    func handle(_ d: Daemon) throws -> Done {
        guard let ls = d.existing(id) else { return Done() }
        if let summary { _ = ls.update { $0.summary = summary }; d.publish(ls) }
        if let st = status.flatMap(AgentStatus.init(rawValue:)) { ls.overrideStatus(st) }
        return Done()
    }
}

extension RecipeRender: Handled {
    func handle(_ d: Daemon) throws -> String {
        let w = try d.cwd(forWorktree: id)
        let cfg = d.trustedConfig(try d.store.repo(w.repoId)?.path ?? w.path)   // the repo's own prompts only once trusted
        var all: [String: String] = ["branch": w.branch, "base": try d.store.repo(w.repoId)?.baseBranch ?? "main"]
        all.merge(vars ?? [:]) { $1 }
        if all["stagedPatch"] == nil { all["stagedPatch"] = String(((try? Git.run(["diff", "--cached", "--stat"], cwd: w.path)) ?? "").prefix(4000)) }
        return Recipes.render(name, config: cfg, vars: all)
    }
}

extension Ping: Handled { func handle(_ d: Daemon) throws -> String { "pong" } }
extension DaemonShutdown: Handled {
    func handle(_ d: Daemon) throws -> Done {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak d] in d?.stop(); exit(0) }
        return Done()
    }
}

/// The agents on this Mac, side by side, each through `offload`; latest from npm where they publish there.
extension AgentsVersions: AsyncHandled {
    func handle(_ d: Daemon) async throws -> [Item] {
        let manifests = AgentManifest.load(dir: d.root.appendingPathComponent("agents"))
        return await withTaskGroup(of: Item?.self) { g in
            for m in manifests {
                g.addTask {
                    try? await d.offload { () -> Item? in
                        let path = d.childPath   // the login shell's PATH: the first read waits for the shell
                        guard let exe = try? LoginPath.resolve(m.command) else { return nil }
                        let v = Daemon.run([exe, "--version"], path: path, timeout: 4).flatMap(Daemon.semver)
                        let npm = try? LoginPath.resolve("npm")
                        let latest = m.npm.flatMap { pkg in npm.flatMap { Daemon.run([$0, "view", pkg, "version"], path: path, timeout: 8) } }.flatMap(Daemon.semver)
                        return Item(id: m.id, version: v, latest: latest)
                    }
                }
            }
            var out: [Item] = []
            for await r in g { if let r { out.append(r) } }
            return out
        }
    }
}

extension TaskFromIssue: AsyncHandled {
    func handle(_ d: Daemon) async throws -> Result {
        guard let r = try d.store.repo(repoId) else { throw RPCError.invalidParams("no repo") }
        let body = body ?? "", url = url ?? ""
        var branch = branch.flatMap { $0.isEmpty ? nil : $0 } ?? IssueRef.branchName(ref.hasPrefix("#") ? String(ref.dropFirst()) : ref.lowercased(), title: title)
        if let branchPrefix, !branchPrefix.isEmpty, !branch.hasPrefix(branchPrefix) { branch = branchPrefix + branch }
        let unique = try await d.offload { [branch] in
            var unique = branch, n = 2
            while Git.branchExists(r.path, unique) { unique = "\(branch)-\(n)"; n += 1 }
            return unique
        }
        let wv = try await d.handle("worktree.create", .obj(["repoId": .string(r.id), "branch": .string(unique), "note": .string("\(ref) \(title)"), "tabs": false]), conn: -1)
        // The record, the repo's config and the agent's PTY: disk and a process, through `offload` like the rest.
        let (w, s) = try await d.offload { () throws -> (Worktree, Session) in
            guard let w = try d.store.update(Worktree.self, try wv.req("id"), {
                $0.issue = ref; $0.issueURL = url; $0.linearIssueId = linearId ?? ""
            }) else { throw RPCError.internalError("worktree vanished") }
            let cfg = d.trustedConfig(r.path)   // its issueCommand / recipes only once the user trusts the file
            let vars = ["title": title, "body": body, "url": url, "ref": ref, "branch": unique]
            var text = cfg.issueCommand.map { Recipes.fill($0, vars) } ?? Recipes.render("issue", config: cfg, vars: vars)
            if let extra = prompt, !extra.isEmpty { text += "\n\n" + extra }
            var o = Daemon.Launch()
            // Typed, not sent, unless asked: the issue's text is whoever filed it, not the user (it could tell the agent anything).
            o.model = model; o.effort = effort; o.profile = profile; o.draft = draft != false; o.openURLs = openURLs == true
            (o.cols, o.rows) = Daemon.Launch.size(cols: cols, rows: rows)
            o.prompt = text; o.title = "\(ref) \(title)".prefix(48).description
            return (w, try d.spawn(cwd: w.path, manifest: d.manifest(agent ?? "claude", command: nil), worktreeId: w.id, o))
        }
        await d.moveLinear(w, to: .inProgress)
        await d.moveJira(w, toName: "progress", category: "indeterminate")
        d.notify("event.changed", "worktree")
        // An untrusted .kelp.yaml's setup didn't run: said, as worktree.create says it, so the caller can ask.
        return Result(worktree: w, session: s, setupNeedsTrust: wv["setupNeedsTrust"]?.bool == true)
    }
}

extension Daemon {
    static let launchMethods: [any Handled.Type] = [SessionCreate.self, TmuxList.self, SessionRestart.self, SessionHandoff.self, HistoryResume.self,
        SessionHook.self, SessionAnnotate.self, RecipeRender.self, Ping.self, DaemonShutdown.self]
}
