import Foundation
import os
import Core
import GitKit
import Agents

extension JSONValue {
    func req(_ k: String) throws -> String {
        guard let s = self[k]?.string else { throw RPCError.invalidParams("missing \(k)") }
        return s
    }
}

/// A method declared in Core (`RPCMethod`) that the daemon answers, sync (`Handled`) or async (`AsyncHandled`), listed
/// once in `Daemon.methods`. Its result is encoded straight into the reply (`answer`), never through a JSONValue.
protocol Answered: RPCMethod {
    /// Applied on the connection's reader thread, after what was sent before it, call or notification: only right in the
    /// order sent, and quick (`Handled` only). Everything else runs on a task of its own, its reply whenever it's ready.
    static var inOrder: Bool { get }
    /// The result as the reply's JSON.
    static func answer(_ p: JSONValue, _ d: Daemon, conn: Int) async throws -> Data
}

/// Answered on a thread of its own (`offload`): git, files, the store. `handle(_:conn:)` for the few that need the asking
/// connection (attach, detach, ui.publish); the rest write `handle(_:)`.
protocol Handled: Answered {
    func handle(_ d: Daemon) throws -> Result
    func handle(_ d: Daemon, conn: Int) throws -> Result
}

extension Handled {
    static var inOrder: Bool { false }
    func handle(_ d: Daemon, conn: Int) throws -> Result { try handle(d) }

    /// On the calling thread: an in-order method's, on the reader thread.
    static func answerNow(_ p: JSONValue, _ d: Daemon, conn: Int) throws -> Data { try JSONEncoder().encode(decoded(p).handle(d, conn: conn)) }
    static func answer(_ p: JSONValue, _ d: Daemon, conn: Int) async throws -> Data { try await d.offload { try answerNow(p, d, conn: conn) } }
}

extension RPCMethod {
    /// The method's params as its type; a bad or missing field is the caller's error.
    static func decoded(_ p: JSONValue) throws -> Self {
        do { return try (p == .null ? .object([:]) : p).decode(Self.self) }
        catch DecodingError.keyNotFound(let k, _) { throw RPCError.invalidParams("missing \(k.stringValue)") }
        catch { throw RPCError.invalidParams("\(name): \(error)") }
    }
}

extension Daemon {
    /// Every method the daemon answers, by name: one list, so none is answered twice (a second entry traps at launch).
    static let methods: [String: any Answered.Type] = {
        let sync: [any Handled.Type] = [DaemonInfo.self, StateGet.self, StateSet.self, SessionRename.self, SessionContextWindow.self,
                                        WorktreeNote.self, RepoWorktreeSizes.self, RepoRemoveWorktrees.self, GitDiscardHunk.self,
                                        RemoteListFolders.self, SessionReport.self, ClientEvents.self, WatchStart.self, WatchStop.self]
            + gitMethods + workspaceMethods + sessionMethods + integrationMethods + projectMethods + launchMethods + uiMethods + lspMethods + extensionMethods
        let all = sync.map { $0 as any Answered.Type } + (asyncMethods + lspAsyncMethods).map { $0 as any Answered.Type }
        return Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    }()

    /// The reply's result, encoded once.
    func answer(_ method: String, _ p: JSONValue, conn: Int) async throws -> Data {
        guard let t = Self.methods[method] else { throw RPCError.methodNotFound }
        if let quiet = try refuseRemoteForge(t, p) { return quiet }
        return try await integrationErrors { try await gitErrors { try await t.answer(p, self, conn: conn) } }
    }

    /// An in-order method, here on the connection's reader thread, where everything sent after it waits: it starts no
    /// program (`Subprocess.quickOnly` refuses one, so the call fails at once instead of holding up the connection), and
    /// one that still took long says so in the log.
    func answerNow(_ t: any Handled.Type, _ p: JSONValue, conn: Int) throws -> Data {
        if let quiet = try refuseRemoteForge(t, p) { return quiet }
        let start = DispatchTime.now()
        defer {
            let ms = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            if ms >= 100 { Log.rpc.error("in-order \(t.name, privacy: .public) held its connection for \(ms) ms") }
        }
        do { return try Subprocess.quickOnly { try t.answerNow(p, self, conn: conn) } } catch let e as GitError { throw RPCError.internalError(e.message) }
    }

    /// The same as a value, for callers that read it by hand (tests).
    func handle(_ method: String, _ p: JSONValue, conn: Int) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: await answer(method, p, conn: conn))
    }

    private func gitErrors<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as GitError { throw RPCError.internalError(e.message) }
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
    /// time limits, so a thread is held only while its program runs; at most `offloadLimit` run at once, the rest wait
    /// their turn in the order they came, holding no thread meanwhile.
    func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        await offloads.acquire()
        return try await withCheckedThrowingContinuation { c in
            Thread.detachNewThread { [offloads] in
                let r = Result(catching: work)
                offloads.release()
                c.resume(with: r)
            }
        }
    }

    /// 128 at once: wider than any fan-out Kelp makes itself (the sidebar's PR per folder, every watched folder's status),
    /// and than the slow ones that once stalled every request (aRequestIsAnsweredWhileManySlowOnesRun holds 80): the next
    /// request still runs while that many wait on hosts that don't answer. Past it, a runaway client queues instead of
    /// starting a program per request: each is a thread here, two more reading its pipes (`Subprocess`) and a process,
    /// and the user's processes are capped for the whole login (kern.maxprocperuid), terminals included.
    static let offloadLimit = 128
}

/// At most `limit` holders at once; the rest wait first come, first served, suspended (no thread held while waiting).
/// Limit: a waiter whose task is cancelled still takes its turn; nothing here cancels (a client's deadline is its own).
final class Slots: Sendable {
    let limit: Int
    private struct State { var held = 0; var waiting: [CheckedContinuation<Void, Never>] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(_ limit: Int) { self.limit = limit }

    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                guard s.held < limit else { s.waiting.append(c); return false }
                s.held += 1; return true
            }
            if now { c.resume() }
        }
    }

    /// The slot passes straight to the longest waiter, if there is one.
    func release() {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard !s.waiting.isEmpty else { s.held -= 1; return nil }
            return s.waiting.removeFirst()
        }
        next?.resume()
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
        guard try d.store.update(Worktree.self, id, { $0.note = note }) != nil else { throw RPCError.invalidParams("no worktree") }
        d.notify(ChangedEvent.worktree); return Done()
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
        guard let data = tail(of: url, bytes: 1 << 20) else { return nil }   // a turn's tool results can be hundreds of KB
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
        guard let data = tail(of: url, bytes: 262_144) else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["type"] as? String == "assistant",
                  let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(4000)) }
        }
        return nil
    }

    /// The file's last `bytes` (all of it when shorter); nil when it can't be opened.
    static func tail(of url: URL, bytes: Int) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? h.readToEnd()) ?? Data()
    }
}
