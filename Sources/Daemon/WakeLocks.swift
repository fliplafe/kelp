import Foundation
import os
import Core

/// One lock per session for what changes whether its program runs: waking it, pausing it, stopping it, deleting it.
/// Per session, not one for the daemon: waiting for one program to exit (up to 3 s) or a slow host doesn't hold up
/// opening any other session.
final class WakeLocks: Sendable {
    private let locks = OSAllocatedUnfairLock<[String: NSLock]>(initialState: [:])

    private func lock(_ id: String) -> NSLock {
        locks.withLock { all in
            if let l = all[id] { return l }
            let l = NSLock(); all[id] = l; return l
        }
    }

    func withLock<T>(_ id: String, _ body: () throws -> T) rethrows -> T { try lock(id).withLock(body) }

    /// Several sessions' at once (a workspace's), taken in one order (by id) so two callers can't each hold what the
    /// other waits for.
    func withLocks<T>(_ ids: [String], _ body: () throws -> T) rethrows -> T {
        let held = Set(ids).sorted().map(lock)
        held.forEach { $0.lock() }
        defer { held.reversed().forEach { $0.unlock() } }
        return try body()
    }
}
