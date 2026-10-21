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
/// `handle(_:conn:)` for the few that need the asking connection (attach, detach, ui.publish); the rest write `handle(_:)`.
protocol Handled: RPCMethod {
    func handle(_ d: Daemon) throws -> Result
    func handle(_ d: Daemon, conn: Int) throws -> Result
}

extension Handled {
    func handle(_ d: Daemon, conn: Int) throws -> Result { try handle(d) }

    static func run(_ p: JSONValue, _ d: Daemon, conn: Int = -1) throws -> JSONValue {
        let m: Self
        do { m = try (p == .null ? .object([:]) : p).decode(Self.self) }
        catch DecodingError.keyNotFound(let k, _) { throw RPCError.invalidParams("missing \(k.stringValue)") }
        catch { throw RPCError.invalidParams("\(name): \(error)") }
        return try .from(m.handle(d, conn: conn))
    }
}

extension Daemon {
    /// Checked before the hand-written methods; the old way stays for what isn't declared yet.
    static let typed = Dictionary(uniqueKeysWithValues: ([DaemonInfo.self, StateGet.self, StateSet.self, SessionRename.self, SessionContextWindow.self,
                                                          WorktreeNote.self, RepoWorktreeSizes.self, RepoRemoveWorktrees.self,
                                                          GitDiscardHunk.self, RemoteListFolders.self, SessionReport.self]
                                                          + gitMethods + workspaceMethods + sessionMethods + integrationMethods
                                                          + projectMethods + launchMethods as [any Handled.Type]).map { ($0.name, $0) })

    func handle(_ method: String, _ p: JSONValue, conn: Int) async throws -> JSONValue {
        if Self.debugWake { lastMethod.withLock { $0 = method } }
        if let e = extra[method] { return try await e(self, p) }
        if let r = try refuseRemoteForge(method, p) { return r }
        return try await integrationErrors { try await dispatch(method, p, conn: conn) }
    }

    private func dispatch(_ method: String, _ p: JSONValue, conn: Int) async throws -> JSONValue {
        do {
            if let t = Self.typed[method] { return try await offload { [self] in try t.run(p, self, conn: conn) } }
            if let t = Self.asyncTyped[method] { return try await t.run(p, self, conn: conn) }
            return try await offload { [self] in try handleSync(method, p, conn: conn) }
        }
        catch let e as GitError { throw RPCError.internalError(e.message) }
    }

    /// Where a project's worktrees go: its name made safe for a folder ("../x" can't leave `worktrees/`) and its id, so two
    /// projects with one name don't share a folder.
    static func worktreesDir(_ root: URL, _ r: Repo) -> URL {
        root.appendingPathComponent("worktrees").appendingPathComponent(Git.slug(r.name).replacingOccurrences(of: ".", with: "-") + "-" + r.id.prefix(8))
    }

    /// git, gh and ssh hold their thread until they exit, and Swift's cooperative pool has one thread per core: a few slow
    /// ones (the sidebar asks every folder's PR at once) would stall every other request, a terminal's attach included.
    /// A thread of its own, not GCD's pool: that one stops at 64 threads (concurrent queues Kelp makes draw from it too),
    /// Swift's tasks run on it as well, and once slow hosts hold them all no request is answered. git, gh and ssh all have
    /// time limits, so the threads stay bounded by what is actually running.
    func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in Thread.detachNewThread { c.resume(with: Result(catching: work)) } }
    }

    func handleSync(_ method: String, _ p: JSONValue, conn: Int) throws -> JSONValue {
        if let t = Self.typed[method] { return try t.run(p, self, conn: conn) }   // also for notifications applied in order
        // Not declared yet: config.* (the old settings names the Accounts pane still uses) and ui.* (relayed to the app as sent).
        if let r = try handleSettings(method, p) ?? handleUI(method, p, conn: conn) { return r }
        throw RPCError.methodNotFound
    }
}

extension DaemonInfo: Handled {
    func handle(_ d: Daemon) throws -> Result {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return Result(path: exe.resolvingSymlinksInPath().path, binaryMTime: Daemon.binaryMTime, pid: Int(getpid()),
                      liveSessions: d.live.all.filter { $0.snapshot.status != .exited }.count)
    }
}

extension GitDiscardHunk: Handled {
    func handle(_ d: Daemon) throws -> Done {
        let w = try d.cwd(forWorktree: id)
        guard let diff = try Git.diff(w.path, source: .unstaged, file: file).first, diff.hunks.indices.contains(hunk),
              diff.hunks[hunk].header == header, fingerprint.map({ $0 == diff.hunks[hunk].fingerprint }) ?? true else {
            throw RPCError.invalidParams("The file changed since it was shown; nothing was discarded.")
        }
        try Git.discardHunk(w.path, diff: diff, hunk: hunk); return Done()
    }
}

extension WorktreeNote: Handled {
    func handle(_ d: Daemon) throws -> Done {
        guard try d.store.updateWorktree(id, { $0.note = note }) != nil else { throw RPCError.invalidParams("no worktree") }
        d.notify("event.changed", "worktree"); return Done()
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
                if let b = w.branch, Git.isRevision(b) { _ = try? Git.run(["branch", "-d", b], cwd: r.path) }   // -d: only if its commits are on another branch
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
        if ls.report(r) != nil { d.publish(ls) }
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
