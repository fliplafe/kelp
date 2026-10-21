import Foundation
import GRDB
import Core
import GitKit
import Agents
import AgentData

/// What goes into starting, pausing and waking a session: its environment and account, the trust answer, resuming its
/// conversation, titles, and the agent manifests.
extension Daemon {

    /// One sentence naming the skills that are turned on (their folders exist).
    static func kelpContext(_ dir: URL) -> String? {
        let on = ["kelp-extensions", "kelp-settings"].filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        guard !on.isEmpty else { return nil }
        return "This Claude Code session runs inside Kelp, a macOS IDE; the user sees Kelp's window, not Claude Code's UI. Any request to add "
            + "or change a panel, tab, list, command, setting or theme means Kelp: follow the \(on.joined(separator: " / ")) skill. "
            + "Never create Claude Code mods, plugins, hooks or MCP servers for such requests — Kelp doesn't load them."
    }

    static func hasPlugins(_ dir: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).contains(where: \.hasDirectoryPath)
    }

    /// One place for a session's environment, used to start it and to wake it: the account profile it was started with
    /// comes back with it (it used to be dropped on wake and restart, so the session returned on the default login).
    func launchEnv(_ m: AgentManifest, _ rec: Session) -> [String: String] {
        var env = m.resolvedEnv
        if let name = rec.profile, let prof = profile(name, agent: m.id) { env[prof.key] = prof.dir }
        // Not into tmux: its server keeps the first client's environment for every pane, whichever tab they're shown in.
        if Tmux.session(rec.argv) == nil { env["KELP_SESSION"] = rec.id }
        env["KELP_SOCKET"] = socketPath; env["KELP_HOME"] = root.path
        env["PATH"] = childPath
        return env
    }

    /// Where a session's Claude conversations are: under its profile's config dir when it has one.
    func claudeProjects(_ rec: Session) -> URL {
        rec.profile.flatMap { profile($0, agent: "claude") }.map { URL(fileURLWithPath: $0.dir).appendingPathComponent("projects") }
            ?? agentHomes.withLock { $0 }.claude
    }

    /// Account profiles keep each agent login in its own config dir: switching needs no re-login.
    static let configDirEnv = ["claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"]
    func profile(_ name: String, agent: String) -> (key: String, dir: String)? {
        guard let key = Self.configDirEnv[agent] else { return nil }
        for p in settings["accounts.profiles"]?.array ?? [] where p["name"]?.string == name && p["agent"]?.string == agent {
            if let d = p["dir"]?.string { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true); return (key, d) }
        }
        return nil
    }

    /// Paused rather than ended when its program stops with the daemon or sits idle, and back where it was when woken: an
    /// agent that resumes its conversation, a tmux terminal (tmux keeps the session, the wake attaches again).
    static func resumable(_ s: Session, _ manifests: [AgentManifest]) -> Bool {
        tmuxName(s) != nil || manifests.first { $0.id == s.agent }?.resumeArgs.isEmpty == false
    }

    /// The manifest its live session reads. A remote agent gets no hooks (they're files on this Mac): its status comes
    /// from the screen, which an agent that has hooks elsewhere would never get read.
    func liveManifest(_ m: AgentManifest, cwd: String, worktreeId: String?, env: [String: String]) -> AgentManifest {
        var out = trustAnswered(m, cwd: cwd, worktreeId: worktreeId, env: env)
        if RemoteHost.of(cwd) != nil { out.hooksSettingsFlag = nil }
        return out
    }

    /// Pause agents that have sat idle (done / waiting) for `hibernateMinutes` with nobody watching.
    func hibernateIdle() {
        let minutes = settings.number("sessions.hibernateMinutes") ?? 0
        guard minutes > 0 else { return }
        let idle = live.all.filter { ls in
            [.done, .waiting, .idle].contains(ls.snapshot.status) && !ls.isAttached && ls.idleSeconds > minutes * 60
        }
        guard !idle.isEmpty else { return }   // twice a second: the agents' folder is read only when someone could pause
        let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
        let candidates = idle.filter { Self.resumable($0.snapshot, manifests) }
        // Off the ticker: waiting for programs to exit (up to 3 s each) must not hold up status for everyone else.
        let start = pausingIdle.withLock { busy -> Bool in
            guard !busy, !candidates.isEmpty else { return false }
            busy = true; return true
        }
        guard start else { return }
        Thread.detachNewThread { [self] in
            for ls in candidates { pauseIdle(ls) }
            pausingIdle.withLock { $0 = false }
        }
    }

    /// Under its wake lock, as a wake is: one that comes meanwhile waits until this program is gone, so two never write one
    /// log. Taken out of `live` only if nobody attached since the check.
    private func pauseIdle(_ ls: LiveSession) {
        wakeLocks.withLock(ls.snapshot.id) {
            guard live.remove(ls, if: { !$0.isAttached }) else { return }
            let s = ls.markHibernated()
            Self.waitGone(ls.pty.terminate())   // SIGKILL after 2 s for what ignores the hangup: a wake must not start a second copy
            publish(s)
        }
    }

    /// The agent's "trust this folder?" is answered by Kelp only when that question is actually coming and the user already
    /// settled it: the agent doesn't trust the session's folder yet (else it asks nothing, and an armed answer could only
    /// ever press a different menu) but does trust the project's main checkout. Anything else, including a repository it
    /// has never seen or one on a remote host, is the user's to answer.
    func trustAnswered(_ m: AgentManifest, cwd: String, worktreeId: String?, env: [String: String]) -> AgentManifest {
        guard m.autoAnswers.contains(AgentManifest.trust) else { return m }
        var out = m
        out.autoAnswers.removeAll { $0 == AgentManifest.trust }
        // A remote project's question is always the user's: decided before any git (over ssh, under its wake lock, for a host
        // that may not answer).
        guard RemoteHost.of(cwd) == nil else { return out }
        // The project only counts for its own workspace's folder: any other cwd passed with its worktreeId is just a folder.
        // (A workspace on another branch of a trusted project is trusted the way Claude trusts a folder, whatever is checked
        // out in it.)
        var project: String?
        if let wid = worktreeId, let w = try? store.worktree(wid), let r = try? store.repo(w.repoId),
           AgentTrust.normal(cwd) == AgentTrust.normal(w.path) || AgentTrust.normal(cwd).hasPrefix(AgentTrust.normal(w.path) + "/"),
           !Self.changesAgentConfig(w.path, base: r.baseBranch) {
            project = r.path
        }
        // The config the agent will read: the session's variables over the daemon's own (a kelpd started from a shell
        // passes on that shell's CLAUDE_CONFIG_DIR), as PTY builds its environment.
        let env = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let expectedAndSettled = !AgentTrust.trusts(agent: m.id, folders: [cwd], env: env)
            && project.map { AgentTrust.trusts(agent: m.id, folders: [$0], env: env) } == true
        return expectedAndSettled ? m : out
    }

    /// What a trusted folder lets an agent run on its own: hooks, MCP servers, its settings. A branch (someone else's PR)
    /// that changes these against the base asks the user, though the project is trusted; so does one Kelp can't compare.
    static let agentConfig = [".claude", ".mcp.json", ".codex", ".gemini", ".cursor"]
    /// At any depth: a session can start in a folder inside the workspace, and the agent reads that folder's config.
    static let agentConfigSpecs = agentConfig.flatMap { [":(glob)**/" + $0, ":(glob)**/" + $0 + "/**"] }
    static func changesAgentConfig(_ path: String, base: String) -> Bool {
        guard Git.isRevision(base) else { return true }   // a base that reads as an option can't be compared: the user is asked
        let committed = (try? Git.run(["diff", "--quiet", base, "HEAD", "--"] + agentConfigSpecs, cwd: path)) == nil   // exit 1: differs (base: checked above)
        let pending = (try? Git.run(["status", "--porcelain", "--"] + agentConfigSpecs, cwd: path))?.isEmpty != true
        return committed || pending
    }

    /// Bring a paused session back under the same id (layout and links stay), resuming its conversation.
    func wake(_ id: String, cols: UInt16 = 120, rows: UInt16 = 32) throws -> LiveSession {
        guard var rec = try store.session(id), rec.status == .hibernated else { throw RPCError.invalidParams("no live session \(id)") }
        let m = try manifest(rec.agent, command: nil, fallbackArgv: rec.argv)
        let argv = resumeArgv(rec, m)
        rec.argv = argv   // the conversation it found is this session's from now on
        let env = launchEnv(m, rec)
        rec.status = .idle
        let ls = try LiveSession(record: rec, manifest: liveManifest(m, cwd: rec.cwd, worktreeId: rec.worktreeId, env: env),
                                 argv: try launchArgv(argv, cwd: rec.cwd, manifest: m, tmux: rec.tmux), env: env,
                                 historyDir: root.appendingPathComponent("history"), cols: cols, rows: rows, callbacks: callbacks(for: rec))
        if rec.tmux != nil { ls.attachedToRunning() }
        live.add(ls)
        publish(ls.snapshot)
        ls.start()
        return ls
    }

    /// argv that brings back this session's own conversation. A remote one's conversations are on its host: the agent's
    /// own "latest in this folder" finds it there.
    func resumeArgv(_ rec: Session, _ m: AgentManifest) -> [String] {
        guard rec.agent == "claude", RemoteHost.of(rec.cwd) == nil, let flag = m.resumeIdFlag, let pin = m.sessionIdFlag else { return m.resuming(rec.argv) }
        if rec.argv.contains(flag) { return rec.argv }
        if let i = rec.argv.firstIndex(of: pin), i + 1 < rec.argv.count {
            // Pinned but nothing typed yet: no conversation to resume, start it under the same id.
            return ClaudeHistory.session(id: rec.argv[i + 1], cwd: rec.cwd, root: claudeProjects(rec)) != nil ? m.resuming(rec.argv) : rec.argv
        }
        let conversations = ClaudeHistory.sessions(cwd: rec.cwd, root: claudeProjects(rec))
        // From before ids were pinned (or restarted with "latest in this folder", which hands it another agent's
        // conversation): the first conversation that started here between this session and the next one, unless another
        // session has it; none → start fresh. Limit: misses prompts typed out of order across sessions.
        let base = rec.argv.filter { !m.resumeArgs.contains($0) }
        let all = (try? store.sessions()) ?? []
        let claimed = Set(all.filter { $0.id != rec.id }.flatMap { s in
            s.argv.indices.dropLast().filter { [pin, flag].contains(s.argv[$0]) }.map { s.argv[$0 + 1].lowercased() }
        })
        let next = all.filter { $0.agent == "claude" && $0.cwd == rec.cwd && $0.createdAt > rec.createdAt }.map(\.createdAt).min() ?? .distantFuture
        let own = conversations
            .filter { $0.started >= rec.createdAt.addingTimeInterval(-2) && $0.started < next && !claimed.contains($0.id.lowercased()) }
            .min { $0.started < $1.started }
        return own.map { base + [flag, $0.id] } ?? base
    }

    /// A running session's record as it is when written, in order with its status changes (see LiveSession.emit): a copy
    /// taken on a request's thread could otherwise land after a newer status and put an old one back.
    func publish(_ ls: LiveSession) {
        ls.inOrder { [weak self, weak ls] in
            guard let self, let ls, !ls.isDiscarded else { return }
            self.publish(ls.snapshot)
        }
    }

    func publish(_ s: Session) {
        do { try store.update(s) } catch {
            // Deleted meanwhile (closed, its project removed): not brought back. Anything else (a full disk) is logged.
            if !(error is RecordError) { Log.store.error("couldn't save session \(s.id, privacy: .public): \(error)") }
            return
        }
        notify(s)
        if s.status == .done || s.status == .waiting, let a = s.agent { planUsed(a) }
    }

    /// Name a session (and optionally its fresh branch) from the first prompt; a manual title always wins.
    /// Runs git: call it off the cooperative pool (it's called on GCD).
    func autoTitle(session id: String, prompt: String) {
        guard let ls = existing(id), !ls.snapshot.titleManual, ls.topic == nil else { return }   // the agent's own topic is better
        let title = Naming.title(prompt)
        let s = ls.update { if !$0.titleManual { $0.title = title } }
        publish(ls)
        // A placeholder branch (task-123, wip, new-worktree…) gets a real name from what the agent was asked to do.
        let renamed = try? store.update(Worktree.self, s.worktreeId ?? "") { w in
            if w.note.range(of: Self.placeholderName, options: .regularExpression) != nil { w.note = title }
        }
        if renamed?.note == title { notify(ChangedEvent.worktree) }
        if let w = try? store.worktree(s.worktreeId ?? ""), w.branch.range(of: #"^(task|wip|tmp|new|new-worktree|untitled|ws)(-\d+)?$"#, options: .regularExpression) != nil,
           let r = try? store.repo(w.repoId), w.path != r.path {
            let base = Naming.slug(prompt)
            var b = base, n = 2
            while Git.branchExists(r.path, b) { b = "\(base)-\(n)"; n += 1 }
            if !base.isEmpty, (try? Git.renameBranch(w.path, from: w.branch, to: b)) != nil {
                _ = try? store.update(Worktree.self, w.id) { $0.branch = b; if $0.note.isEmpty { $0.note = title } }
                notify(ChangedEvent.worktree)
            }
        }
    }

    /// The agent's own short topic (Claude Code's terminal title) names the session instead of its prompt, and its
    /// workspace while that still has the name the session gave it (or a placeholder). A title set by hand stays.
    func retitle(session id: String, topic: String) {
        guard let ls = existing(id), !ls.snapshot.titleManual, ls.snapshot.title != topic else { return }
        let old = ls.snapshot.title
        let s = ls.update { if !$0.titleManual { $0.title = topic } }
        publish(ls)
        let renamed = try? store.update(Worktree.self, s.worktreeId ?? "") { w in
            if (!old.isEmpty && w.note == old) || w.note.range(of: Self.placeholderName, options: .regularExpression) != nil { w.note = topic }
        }
        if renamed?.note == topic { notify(ChangedEvent.worktree) }
    }

    func manifest(_ id: String?, command: String?, fallbackArgv: [String]? = nil) throws -> AgentManifest {
        if let command { return .custom(command) }
        if id == "custom", let a = fallbackArgv { return .init(id: "custom", name: "Custom", command: a.first ?? "/bin/zsh", args: Array(a.dropFirst())) }
        let id = id ?? "shell"
        // A plain shell has no meaningful "done": keep the heuristic quiet.
        if id == "shell" { return .init(id: "shell", name: "Shell", command: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", args: ["-l"], quietSeconds: 1e9) }
        guard let m = AgentManifest.load(dir: root.appendingPathComponent("agents")).first(where: { $0.id == id }) else {
            throw RPCError.invalidParams("unknown agent \(id)")
        }
        return m
    }

    func cwd(forWorktree id: String) throws -> Worktree {
        guard let w = try store.worktree(id) else { throw RPCError.invalidParams("no worktree \(id)") }
        return w
    }
}
