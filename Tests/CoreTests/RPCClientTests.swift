import Foundation
import Testing
@testable import Core
import TestSupport

/// A write a daemon that stopped reading never took is cut off part way: the connection closes, so the next line isn't
/// glued to half of this one and refused (or taken for something else) for good.
@Test func aWriteThatGivesUpClosesTheConnection() async throws {
    let path = NSTemporaryDirectory() + "kelp-cut-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer { close(server); unlink(path) }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)   // and never reads
    defer { close(peer) }
    let closed = Flag()
    client.onClose = { closed.set() }
    client.notify("big", .string(String(repeating: "x", count: 8 << 20)))
    // A partial write after the 10 s send timeout, another 10 s, then the 5 s poll: about 25 s.
    for _ in 0..<400 where !closed.value { try await Task.sleep(for: .milliseconds(100)) }
    #expect(closed.value)
}
