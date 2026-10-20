import Foundation
import Testing
import Core
import Daemon
@testable import KelpApp

/// The terminal fallback (SwiftTerm) gets a session's history before any live output, though live output and the attach
/// reply reach the main actor by different hops.
/// Tests that point `AppModel.shared` at a daemon of their own: one at a time, or one would swap the other's client.
@Suite(.serialized) @MainActor struct SharedAppModel {}

extension SharedAppModel {
@Test func attachShowsHistoryBeforeLiveOutput() async throws {
    _ = testHome
    let root = URL(fileURLWithPath: "/tmp/ka-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let c = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
    let count = "i=0; while :; do i=$((i+1)); echo n$i; done"   // live output never stops
    let s: Session = try await c.call("session.create", .obj(["cwd": .string(root.path), "command": .string(count)]), as: Session.self)
    let m = AppModel.shared
    let saved = m.client
    defer { m.detach(session: s.id); m.client = saved }
    m.client = c; m.listen(c)
    func printed() async -> Int {   // the last number it printed
        let tail = (try? await c.call("session.read", .obj(["id": .string(s.id), "bytes": 200])))?.string ?? ""
        return tail.split(whereSeparator: \.isNewline).dropLast().last.flatMap { Int($0.drop { !$0.isNumber }) } ?? 0
    }
    for _ in 0..<200 where await printed() < 2000 {
        try await Task.sleep(for: .milliseconds(50))   // a history worth checking first (slow on a loaded machine)
    }
    var got = Data()
    await m.attach(session: s.id) { got.append($0) }
    for _ in 0..<20 { try await Task.sleep(for: .milliseconds(50)) }   // live output keeps coming meanwhile
    let numbers = String(decoding: got, as: UTF8.self).split(whereSeparator: \.isNewline).dropFirst().dropLast().compactMap { Int($0.drop { !$0.isNumber }) }
    #expect(numbers.count > 100)
    #expect(zip(numbers, numbers.dropFirst()).allSatisfy { $0 < $1 }, "out of order")
}
}
