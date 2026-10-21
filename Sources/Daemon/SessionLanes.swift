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
        let q = lanes.withLock { l -> DispatchQueue in
            var lane = l[id] ?? Lane(queue: DispatchQueue(label: "kelp.session-lane"))
            lane.waiting += 1; l[id] = lane
            return lane.queue
        }
        q.async { [self] in work(); lanes.withLock { $0[id]?.waiting -= 1 } }
    }
}

extension Daemon {
    /// `use` with the running session `id`: right away when it runs and nothing for it waits, else on its lane once it's
    /// woken (a wake that fails then is logged: the caller already has its answer).
    func whenRunning(_ id: String, _ use: @escaping @Sendable (LiveSession) throws -> Void) throws {
        if lanes.isClear(id), let ls = existing(id) { try use(ls); return }
        guard try existing(id) != nil || store.session(id)?.status == .hibernated else { throw RPCError.invalidParams("no live session \(id)") }
        lanes.run(id) { [self] in
            do { try use(try liveSession(id)) }
            catch { Log.session.error("input for \(id, privacy: .public) after waking it failed: \(error)") }
        }
    }
}
