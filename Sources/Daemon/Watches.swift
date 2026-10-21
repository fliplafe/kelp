import Foundation
import os
import Core
import GitKit

/// What clients watch (`watch.start`). A topic and key is read only while someone watches it, once for all of them, and
/// pushed to them when it changed: the first value right away, the last one to whoever joins. A git topic is read when its
/// folder's files change (FSEvents here, not one watcher per panel in the app); the rest on their topic's clock, which
/// each read sets (CI goes on only while a run does). A connection that goes away stops watching.
final class Watches: Sendable {
    struct Key: Hashable, Sendable { let topic: WatchTopic, key: String }
    private struct Entry {
        var watchers: Set<Int>
        var last: Data?                // the event as last sent (sorted keys): the next goes out only when it differs
        var reading = false, again = false
        var timer: Int?                // the scheduled read's number; a newer one (or none) makes it a no-op
        var files: FileWatcher?
        var fastUntil = Date.distantPast
        var tag: String?               // context: the session's status at the last read
    }
    private let entries = OSAllocatedUnfairLock<[Key: Entry]>(initialState: [:])
    private let timers = OSAllocatedUnfairLock(initialState: 0)
    /// Reads so far by key: tests see one read for two watchers, and none after the last one left.
    let reads = OSAllocatedUnfairLock<[Key: Int]>(initialState: [:])
    var running: Int { entries.withLock { $0.count } }
    private let files = DispatchQueue(label: "kelp.watches.files")

    func start(_ k: Key, conn: Int, _ d: Daemon) {
        let (new, again, last) = entries.withLock { e -> (Bool, Bool, Data?) in
            guard var x = e[k] else { e[k] = Entry(watchers: [conn]); return (true, false, nil) }
            let again = !x.watchers.insert(conn).inserted
            if again { x.fastUntil = Date().addingTimeInterval(45) }
            e[k] = x
            return (false, again, x.last)
        }
        if new { begin(k, d) } else if again { read(k, d) } else if let last { d.clients.targets([conn]).forEach { $0.send(last) } }
    }

    func stop(_ k: Key, conn: Int) {
        let gone = entries.withLock { e -> Entry? in
            guard var x = e[k] else { return nil }
            x.watchers.remove(conn)
            if x.watchers.isEmpty { e[k] = nil; return x }
            e[k] = x; return nil
        }
        _ = gone   // its scheduled read finds it gone; its FileWatcher stops as it goes
    }

    /// A connection went away.
    func drop(_ conn: Int) {
        let gone = entries.withLock { e -> [Entry] in
            var out: [Entry] = []
            for (k, var x) in e where x.watchers.contains(conn) {
                x.watchers.remove(conn)
                if x.watchers.isEmpty { e[k] = nil; out.append(x) } else { e[k] = x }
            }
            return out
        }
        _ = gone   // released here, out of the lock: their FileWatchers stop as they go
    }

    func stopAll() { let all = entries.withLock { e in defer { e = [:] }; return e }; _ = all }

    /// Something says it may have changed (a session's status, for its context): read again if it did.
    func touched(_ k: Key, tag: String, _ d: Daemon) {
        let go = entries.withLock { e -> Bool in
            guard var x = e[k], x.tag != tag else { return false }
            x.tag = tag; e[k] = x; return true
        }
        if go { read(k, d) }
    }

    private func begin(_ k: Key, _ d: Daemon) {
        if k.topic == .git, let w = try? d.store.worktree(k.key), RemoteHost.of(w.path) == nil {
            // Debounced: a save is several events, a checkout hundreds.
            let fw = FileWatcher(root: w.path, deliver: files) { [weak self, weak d] paths in
                guard let self, let d, Git.touchesStatus(paths) else { return }
                soon(k, d)
            }
            entries.withLock { e in e[k]?.files = fw }
        }
        read(k, d)
    }

    private func soon(_ k: Key, _ d: Daemon) {
        let pending = entries.withLock { $0[k]?.timer != nil }
        if !pending { schedule(k, after: 0.4, d) }
    }

    private func schedule(_ k: Key, after t: TimeInterval, _ d: Daemon) {
        let n = timers.withLock { $0 += 1; return $0 }
        let ok = entries.withLock { e -> Bool in
            guard var x = e[k] else { return false }
            x.timer = n; e[k] = x; return true
        }
        guard ok else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + t) { [weak self, weak d] in
            guard let self, let d, entries.withLock({ $0[k]?.timer == n }) else { return }   // stopped, or read since
            read(k, d)
        }
    }

    private func read(_ k: Key, _ d: Daemon) {
        let go = entries.withLock { e -> Date? in
            guard var x = e[k] else { return nil }
            if x.reading { x.again = true; e[k] = x; return nil }
            x.reading = true; x.timer = nil; e[k] = x
            return x.fastUntil
        }
        guard let fastUntil = go else { return }
        Task {
            let (line, next) = await Self.sample(k, d, fast: fastUntil > Date())
            reads.withLock { $0[k, default: 0] += 1 }
            let (send, to, again) = entries.withLock { e -> (Data?, Set<Int>, Bool) in
                guard var x = e[k] else { return (nil, [], false) }   // stopped meanwhile
                x.reading = false
                let changed = line != nil && line != x.last
                if changed { x.last = line }
                let again = x.again; x.again = false
                e[k] = x
                return (changed ? line : nil, x.watchers, again)
            }
            if let send { d.clients.targets(to).forEach { $0.send(send) } }
            if again { read(k, d) } else if let next { schedule(k, after: next, d) }
        }
    }

    /// The topic's event as it is now, as sent (nil: nothing to say, a failure that stays quiet), and when to read it
    /// again with nothing else saying so (nil: only when something does).
    private static func sample(_ k: Key, _ d: Daemon, fast: Bool) async -> (Data?, TimeInterval?) {
        switch k.topic {
        case .git:
            // A remote project's folder here holds only its marker: no file events come, so it's read now and then.
            let remote = (try? d.store.worktree(k.key)).flatMap { $0 }.map { RemoteHost.of($0.path) != nil } ?? false
            var e: GitEvent
            do {
                let changes = try await d.ask(GitStatus(id: k.key))
                e = GitEvent(worktree: k.key, changes: changes, branches: try await d.ask(GitBranches(id: k.key)))
                e.stats = changes.isEmpty ? LineStats() : try? await d.ask(GitLineStats(id: k.key))
            } catch { e = GitEvent(worktree: k.key, error: message(error)) }
            return (line(e), remote ? 10 : nil)   // Limit: a remote folder is read every 10 s while watched
        case .ports:
            return ((try? await d.ask(PortsList(worktreeId: k.key))).flatMap { line(PortsEvent(worktree: k.key, ports: $0)) }, 3)
        case .activity:
            do { return (line(ActivityEvent(usage: try await d.ask(SessionUsage()))), 2) }
            catch { return (line(ActivityEvent(error: message(error))), 2) }
        case .ci:
            // gh / glab ask the forge: again only while a run goes on (or just after a push asked, `fast`).
            do {
                let r = try await d.ask(CIRunsList(worktreeId: k.key))
                let running = CIRuns.latest(r.runs).contains { $0.status != "completed" }
                return (line(CIEvent(worktree: k.key, result: r)), running ? 10 : fast ? 5 : nil)
            } catch { return (line(CIEvent(worktree: k.key, error: message(error))), nil) }
        case .pr:
            return ((try? await d.ask(GitHubBranchPR(worktreeId: k.key))).flatMap { line(PREvent(worktree: k.key, pr: $0)) }, 60)
        case .context:
            // A 1 MB transcript tail: while the agent works, and when its status changes (`touched`).
            let usage = try? await d.ask(SessionContextWindow(id: k.key))
            let working = d.existing(k.key)?.snapshot.status == .working
            return (line(ContextEvent(session: k.key, usage: usage ?? nil)), working ? 15 : nil)
        case .limits:
            // From memory (the probes read the plans on their own clock): cheap.
            return ((try? await d.ask(UsageGet())).flatMap { line(LimitsEvent(usage: $0)) }, 10)
        }
    }

    private static func line(_ e: some RPCEvent) -> Data? {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        guard var d = try? enc.encode(RPCNotification(e)) else { return nil }
        d.append(0x0A)
        return d
    }

    private static func message(_ e: Error) -> String { (e as? RPCError)?.message ?? "\(e)" }
}

extension Daemon {
    /// A method answered as a client would get it (refusals and error mapping included), its result as its type.
    func ask<M: Answered>(_ m: M) async throws -> M.Result {
        try JSONDecoder().decode(M.Result.self, from: await answer(M.name, try m.params() ?? .null, conn: -1))
    }

    /// A project or workspace record changed: the record goes to every client (they keep their lists from these).
    func recordChanged(_ c: Store.Change) {
        switch c {
        case .repo(let r): notify(r)
        case .worktree(let w): notify(w)
        case .repoRemoved(let id): notify(RemovedEvent(repo: id))
        case .worktreeRemoved(let id): notify(RemovedEvent(worktree: id))
        }
    }
}

extension WatchStart: Handled {
    static var inOrder: Bool { true }   // a start and a stop sent in a row apply in that order
    func handle(_ d: Daemon) throws -> Done { throw RPCError.internalError("needs its connection") }
    func handle(_ d: Daemon, conn: Int) throws -> Done { d.watches.start(.init(topic: topic, key: key), conn: conn, d); return Done() }
}

extension WatchStop: Handled {
    static var inOrder: Bool { true }
    func handle(_ d: Daemon) throws -> Done { throw RPCError.internalError("needs its connection") }
    func handle(_ d: Daemon, conn: Int) throws -> Done { d.watches.stop(.init(topic: topic, key: key), conn: conn); return Done() }
}
