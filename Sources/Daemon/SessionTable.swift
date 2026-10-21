import Foundation
import Core

/// The sessions whose program runs now, by id. Paused and ended ones are only in the store.
final class SessionTable: Sendable {
    private let table = Locked<[String: LiveSession]>([:])

    subscript(id: String) -> LiveSession? { table.withLock { $0[id] } }
    var all: [LiveSession] { table.withLock { Array($0.values) } }
    func add(_ ls: LiveSession) { table.withLock { $0[ls.snapshot.id] = ls } }
    /// Out of the table (paused, deleted): what was there.
    func remove(_ id: String) -> LiveSession? { table.withLock { $0.removeValue(forKey: id) } }
    /// Out only if `ls` is still the one there and `ok` says so, checked under the same lock.
    func remove(_ ls: LiveSession, if ok: (LiveSession) -> Bool = { _ in true }) -> Bool {
        table.withLock { t in
            let id = ls.snapshot.id
            guard t[id] === ls, ok(ls) else { return false }
            t[id] = nil; return true
        }
    }
}
