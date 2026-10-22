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
        } else if command == nil, (agent ?? "shell") == "shell", d.settings["terminal.tmux"]?.bool == true,
                  RemoteHost.of(dir) != nil || (try? LoginPath.resolve("tmux")) != nil {
            o.argv = Tmux.argv(Tmux.own())   // a terminal in a tmux session of its own, which ends with it (Tmux.isOwn)
        }
        return try d.spawn(cwd: dir, manifest: d.manifest(tmux == nil ? agent : "shell", command: tmux == nil ? command : nil),
                                 worktreeId: worktreeId, o)
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
        // A remote agent still running in its tmux session on the host: the new tab attaches to it (after a dropped
        // connection, that's all a restart is), so there's still one copy. Starting afresh ends it.
        if resume != false { o.tmux = old.tmux }
        // The new session pins an id of its own, never the old one's.
        o.argv = Daemon.withoutSessionId(resume != false ? d.resumeArgv(old, m) : old.argv, flag: m.sessionIdFlag)
        let s = try d.spawn(cwd: old.cwd, manifest: m, worktreeId: old.worktreeId, o)
        d.discard(old, keepTmux: old.tmux == nil || resume != false)   // its exit, still to come, doesn't save it again
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
    static var quick: Bool { true }   // the agent waits for its hook
    func handle(_ d: Daemon) throws -> Done {
        guard let ls = d.existing(id) else { return Done() }
        if let transcript, !transcript.isEmpty { ls.transcriptPath = transcript; d.follow(ls, transcript: transcript) }
        if let cwd, ls.workIn(cwd) != nil { d.publish(ls) }
        if let notification, Hooks.isIdleReminder(notification) { return Done() }
        guard let event else { throw RPCError.invalidParams("missing event") }
        let background = Hooks.hasBackgroundWork(.obj(["background_tasks": .array(backgroundTasks ?? [])]))
        ls.hook(event == "done" && background ? "working" : event, trigger: trigger, message: notification?["message"]?.string)
        return Done()
    }
}

extension SessionAnnotate: Handled {
    static var quick: Bool { true }
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

extension Ping: Handled {
    static var quick: Bool { true }
    func handle(_ d: Daemon) throws -> String { "pong" }
}
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
        let created = try await d.offload { try WorktreeCreate(repoId: r.id, branch: unique, note: "\(ref) \(title)", tabs: false).handle(d) }
        // The record, the repo's config and the agent's PTY: disk and a process, through `offload` like the rest.
        let (w, s) = try await d.offload { () throws -> (Worktree, Session) in
            guard let w = try d.store.update(Worktree.self, created.worktree.id, {
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
        await d.forges.moveLinear(w, to: .inProgress)
        await d.forges.moveJira(w, toName: "progress", category: "indeterminate")
        d.notify(ChangedEvent.worktree)
        // An untrusted .kelp.yaml's setup didn't run: said, as worktree.create says it, so the caller can ask.
        return Result(worktree: w, session: s, setupNeedsTrust: created.setupNeedsTrust == true)
    }
}

extension Daemon {
    static let launchMethods: [any Handled.Type] = [SessionCreate.self, TmuxList.self, SessionRestart.self, SessionHandoff.self, HistoryResume.self,
        SessionHook.self, SessionAnnotate.self, RecipeRender.self, Ping.self, DaemonShutdown.self, ProcessRun.self, ProcessWhich.self]
}

extension ProcessWhich: Handled {
    func handle(_ d: Daemon) throws -> Result {
        Dictionary(commands.compactMap { c in (try? LoginPath.resolve(c)).map { (c, $0) } }) { a, _ in a }
    }
}

extension ProcessRun: Handled {
    func handle(_ d: Daemon) throws -> Result {
        guard argv.first?.isEmpty == false else { throw RPCError.invalidParams("Nothing to run.") }
        if let extensionId { try d.requireEnabledExtension(extensionId) }
        // What sessions get (PATH with `kelp` on it, this home), minus the markers of whatever started the daemon.
        var env = ProcessInfo.processInfo.environment.filter { k, _ in !PTY.scrubbed.contains { k.hasPrefix($0) } }
        env["PATH"] = d.childPath; env["KELP_HOME"] = d.root.path; env["KELP_SOCKET"] = d.socketPath
        let dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory()
        let r = try Subprocess.run(argv, cwd: dir, env: env, stdin: stdin.map { Data($0.utf8) }, timeLimit: max(0.1, min(timeLimit ?? 60, 86400)),
                                   limit: Self.outputLimit)
        // Not a part as if it were all of it: a formatter's would replace the file's text.
        guard !r.truncated else {
            let name = ((argv.first ?? "") as NSString).lastPathComponent
            throw RPCError.internalError("\(name) printed more than \(Self.outputLimit >> 20) MB, more than Kelp reads.")
        }
        // Lossy on purpose: a tool's output with a stray byte should still show.
        return Result(code: r.status, stdout: String(decoding: r.stdout, as: UTF8.self), stderr: String(decoding: r.stderr, as: UTF8.self),
                      timedOut: r.timedOut)
    }

    /// Of each stream: the reply carries both, JSON-escaped (a control byte takes six), under a connection's `backlogLimit`.
    static let outputLimit = 16 << 20
}

extension Daemon {
    /// An extension's command runs only while that extension is installed and on (Settings › Extensions): a page or a
    /// list left open after turning it off can't run it any more. `id` is its folder's name; the manifest has its id.
    func requireEnabledExtension(_ id: String) throws {
        struct Manifest: Decodable { var id: String; var name: String? }
        let file = root.appendingPathComponent("extensions").appendingPathComponent(id).appendingPathComponent("extension.json")   // Paths.extensions of this home
        guard !id.isEmpty, (id as NSString).lastPathComponent == id, id != "..", id != ".",
              let data = FileManager.default.contents(atPath: file.path),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { throw RPCError.invalidParams("No extension \"\(id)\".") }
        // Limit: unset means none of the user's extensions is off (the app's default-off list names built-ins only).
        let off = Set(settings["extensions.disabled"]?.array?.compactMap(\.string) ?? [])
        guard !off.contains(m.id) else { throw RPCError.invalidParams("The extension “\(m.name ?? m.id)” is turned off.") }
    }
}
