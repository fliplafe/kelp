import Foundation
import os
import Core

/// What an in-order handler mustn't do on the connection's reader thread: wake a paused session (git, files, a spawn
/// can take seconds, and everything else that connection sends would wait behind it — the app's main thread too, once
/// the socket fills). Each session has a serial lane: input for a paused one wakes it there, and input after it follows.
final class SessionLanes: Sendable {
    private struct Lane { let queue: DispatchQueue; var waiting = 0 }
    private let lanes = OSAllocatedUnfairLock<[String: Lane]>(initialState: [:])

    /// Nothing for `id` waits on its lane: new input may go straight to the running session.
    func isClear(_ id: String) -> Bool { lanes.withLock { ($0[id]?.waiting ?? 0) == 0 } }

    /// `work` on `id`'s lane, after what's already there. Limit: a lane stays for the daemon's life (one idle queue
    /// per session that was ever woken by input); drop it when its session ends if that ever adds up.
    func run(_ id: String, _ work: @escaping @Sendable () -> Void) {
        let q = enter(id)
        q.async { [self] in work(); leave(id) }
    }

    /// `work` on `id`'s lane after what's already there, this thread waiting for it (one that may block: not a reader).
    func runHere<T>(_ id: String, _ work: () throws -> T) rethrows -> T {
        let q = enter(id)
        defer { leave(id) }
        return try q.sync(execute: work)
    }

    private func enter(_ id: String) -> DispatchQueue {
        lanes.withLock { l in
            var lane = l[id] ?? Lane(queue: DispatchQueue(label: "kelp.session-lane"))
            lane.waiting += 1; l[id] = lane
            return lane.queue
        }
    }
    private func leave(_ id: String) { lanes.withLock { $0[id]?.waiting -= 1 } }
}

/// Input for a session (keys, text), in the order sent: to the running session right away when nothing for it waits on
/// its lane, else on the lane after what's there, a paused session woken first. Either way the reply goes out once the
/// session has it, or with why it couldn't (a wake that failed): the reader thread reads on meanwhile.
protocol SessionInput: Handled {
    var id: String { get }
    func apply(to s: LiveSession) throws -> Result
}

extension SessionInput {
    /// Off the reader thread (another handler, a test): here, in order with the session's other input.
    func handle(_ d: Daemon) throws -> Result {
        if d.sessions.lanes.isClear(id), let ls = d.sessions.existing(id) { return try apply(to: ls) }
        try d.sessions.mustWake(id)
        return try d.sessions.lanes.runHere(id) { try apply(to: d.sessions.liveSession(id)) }
    }

    /// On the connection's reader thread: `done` with the reply's result, now or from the lane.
    static func answerInOrder(_ p: JSONValue, _ d: Daemon, done: @escaping @Sendable (Swift.Result<Data, Error>) -> Void) {
        do {
            let m = try decoded(p)
            if d.sessions.lanes.isClear(m.id), let ls = d.sessions.existing(m.id) { done(.success(try JSONEncoder().encode(m.apply(to: ls)))); return }
            try d.sessions.mustWake(m.id)
            d.sessions.lanes.run(m.id) { done(Swift.Result { try JSONEncoder().encode(m.apply(to: d.sessions.liveSession(m.id))) }) }
        } catch { done(.failure(error)) }
    }
}
