import Foundation
import Core

/// A client of the socket. Writes leave in order from the connection's own queue, so no caller waits on a client that
/// reads slowly (or not at all), and its fd closes only after them: a reply can't land in a later connection or a
/// PTY that got the same number.
final class Connection: @unchecked Sendable {   // queued/closing/closed under lock; writes serialized on q
    let id: Int
    let fd: Int32
    private let q = DispatchQueue(label: "kelp.connection")
    private let lock = NSLock()
    private var queued = 0, closing = false, closed = false
    /// A client this far behind isn't reading: it's hung up on rather than waited for.
    static let backlogLimit = 16 << 20

    /// The program that connected (`Unix.peerExecutable`), for what only Kelp's window may do.
    let peer: String?

    init(id: Int, fd: Int32) { self.id = id; self.fd = fd; peer = Unix.peerExecutable(fd) }

    func send(_ d: Data) {
        // Queued under the lock that `close` takes too: a write checked before the close is also queued before it, so
        // it never runs after the fd was closed (and its number given to a new client or a PTY).
        let behind = lock.withLock { () -> Int? in
            guard !closing else { return nil }
            queued += d.count
            q.async { [self] in
                Unix.writeAll(fd, d)
                lock.withLock { queued -= d.count }
            }
            return queued
        }
        if let behind, behind > Self.backlogLimit { hangUp() }
    }

    /// Reading and writing stop now (a stalled client, the daemon quitting): its reader sees EOF, queued writes fail fast.
    func hangUp() { lock.withLock { if !closed { _ = shutdown(fd, SHUT_RDWR) } } }

    /// Nothing more is sent; the fd closes once what's queued is out.
    func close() {
        lock.withLock {
            closing = true
            q.async { [self] in lock.withLock { closed = true; _ = Darwin.close(fd) } }
        }
    }
}
