import Foundation
import os
import Core

/// Who is connected to the socket: each client, which of them are raw byte pipes (`kelp attach`), which is Kelp's window
/// (and what it last said it shows). Under a lock of its own.
///
/// Lock order in the daemon, outermost first: a session's wake lock (`Sessions.wakeLocks`, several taken by id) → `Sessions.live` →
/// `Clients` → a session's own lock →
/// a `Connection`'s. (A session's lock is never held while another is taken: output, status and hooks call out after.) `attachIfConnected` holds this one while it subscribes, and the reader's cleanup takes it
/// first, so a connection is either subscribed and then cleaned up, or never subscribed.
final class Clients: Sendable {
    private struct State {
        var all: [Int: Connection] = [:], next = 1
        var raw = Set<Int>()          // byte pipes, and new ones until their first request says they aren't: no JSON events go to them
        var app = Set<Int>()          // Kelp's window (ui.publish): it gets event.ui
        var muted = Set<Int>()        // asked for no broadcasts (client.events): kelp attach's control connection
        var uiState: JSONValue = .object([:])   // what the app last published; cleared when no app is connected
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Raw until it asks for something (`kelp attach` sends `session.stream` first): an event broadcast before then would
    /// land in its byte stream, on the screen.
    func add(fd: Int32) -> Connection {
        state.withLock { s in
            let c = Connection(id: s.next, fd: fd)
            s.next += 1
            s.all[c.id] = c
            s.raw.insert(c.id)
            return c
        }
    }

    /// Gone: it gets nothing more, and the app's published state goes with the last app.
    func remove(_ id: Int) {
        state.withLock { s in
            s.all[id] = nil
            s.raw.remove(id)
            s.muted.remove(id)
            if s.app.remove(id) != nil, s.app.isEmpty { s.uiState = .object([:]) }
        }
    }

    func everyone() -> [Connection] { state.withLock { Array($0.all.values) } }
    func peer(_ id: Int) -> String? { state.withLock { $0.all[id]?.peer } }
    func peerPID(_ id: Int) -> pid_t? { state.withLock { $0.all[id]?.peerPID } }
    func setRaw(_ id: Int, _ on: Bool) { state.withLock { s in if on { s.raw.insert(id) } else { s.raw.remove(id) } } }

    /// Runs `body` only while `id` is still connected, under this lock (see the lock order above).
    func ifConnected(_ id: Int, _ body: () -> Void) { state.withLockUnchecked { if $0.all[id] != nil { body() } } }   // body runs here, never later

    /// Subscribers of a session's output: the raw ones (bytes) and the rest (a JSON event).
    func split(_ subs: Set<Int>) -> (raw: [Connection], json: Set<Int>) {
        state.withLock { s in (subs.filter { s.raw.contains($0) }.compactMap { s.all[$0] }, subs.subtracting(s.raw)) }
    }

    /// Who gets a JSON event: everyone but the raw pipes and those that asked for none, or only those in `only`.
    func targets(_ only: Set<Int>?) -> [Connection] {
        state.withLock { s in
            s.all.filter { id, _ in !s.raw.contains(id) && (only.map { $0.contains(id) } ?? !s.muted.contains(id)) }.map(\.value)
        }
    }

    /// A JSON event to `targets(only)`, encoded once.
    func notify(_ e: some RPCEvent, to only: Set<Int>? = nil) {
        guard let d = try? Wire.line(RPCNotification(e)) else { return }
        targets(only).forEach { $0.send(d) }
    }

    func setMuted(_ id: Int, _ muted: Bool) { state.withLock { if muted { $0.muted.insert(id) } else { $0.muted.remove(id) } } }

    func publishUI(_ ui: JSONValue, from id: Int) { state.withLock { $0.uiState = ui; $0.app.insert(id) } }
    var uiState: JSONValue { state.withLock { $0.uiState } }
    var apps: Set<Int> { state.withLock { $0.app.subtracting($0.raw) } }
}
