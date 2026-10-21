import Foundation
import Testing
import Core
@testable import Daemon

/// `calls` written to the daemon in one write, as one connection sends them back to back; every line read (events
/// included) until each has its reply and nothing more comes for half a second, at most 10 s.
private func sendAtOnce(_ root: URL, _ calls: [(String, JSONValue)]) throws -> [JSONValue] {
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
    defer { close(fd) }
    var t = timeval(tv_sec: 10, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
    var batch = Data()
    for (i, c) in calls.enumerated() { batch += try Wire.line(RPCRequest(id: i + 1, method: c.0, params: c.1)) }
    Unix.writeAll(fd, batch)
    var lb = LineBuffer(), buf = [UInt8](repeating: 0, count: 65536), lines: [JSONValue] = []
    var replied = false
    while true {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { break }
        lines += try lb.append(Data(buf[0..<n])).map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        if !replied, lines.filter({ $0["id"] != nil }).count >= calls.count {   // then the events still on their way, for 0.5 s
            replied = true; t = timeval(tv_sec: 0, tv_usec: 500_000)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        }
    }
    return lines
}

/// A colour dragged or a stepper held sends settings.set after settings.set: they apply and answer in the order sent, so
/// the last one is what stays, in settings.json and in what the app hears. Each used to run on a thread of its own.
@Test func quickSettingsSetsApplyInTheOrderSent() async throws {
    let (d, _, root) = try daemon(); defer { d.stop() }
    let n = 40
    let lines = try sendAtOnce(root, (1...n).map { (SettingsSet.name, .obj(["key": "terminal.fontSize", "value": .int(10 + $0)])) })
    #expect(lines.compactMap { $0["id"]?.int } == Array(1...n))
    let file = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
    #expect(file["terminal.fontSize"] == .int(10 + n))
    #expect(lines.last { $0["method"] == "event.settings" }?["params"]?["settings"]?["terminal.fontSize"] == .int(10 + n))
}

/// Sends written one after another reach the agent in that order. (A busy program gets queued text one at a time, once it
/// has been quiet a moment: a few sends take a while.)
@Test func sendsReachTheSessionInTheOrderSent() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "order")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "stty -echo; echo ready; exec cat"))
    #expect(try await waitFor(10) { try await w.c.call(SessionRead(id: s.id)).contains("ready") })
    let n = 6
    _ = try sendAtOnce(w.root, (1...n).map { (SessionSend.name, .obj(["id": .string(s.id), "text": .string("m\($0)")])) })
    var got: [String] = []
    _ = try await waitFor(30) {
        got = try await w.c.call(SessionRead(id: s.id)).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("m") && Int($0.dropFirst()) != nil }
        return got.count == n
    }
    #expect(got == (1...n).map { "m\($0)" })
}

/// `kelp attach`'s control connection only sends sizes: once it says so (client.events), broadcasts skip it, as they
/// still reach every other client. Each open terminal used to be one more reader of every event.
@Test func aConnectionThatWantsNoEventsGetsNone() async throws {
    let (d, c, root) = try daemon(); defer { d.stop() }
    func listener(muted: Bool) throws -> Int32 {
        let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
        var t = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        if muted { Unix.writeAll(fd, try Wire.line(RPCRequest(id: nil, method: ClientEvents.name, params: .obj(["events": false])))) }
        return fd
    }
    let quiet = try listener(muted: true), loud = try listener(muted: false)
    defer { close(quiet); close(loud) }
    _ = try await c.call(Ping())   // after the daemon took both connections and the notification
    _ = try await c.call(SettingsSet(key: "terminal.fontSize", value: .int(13)))   // broadcasts event.settings
    func heard(_ fd: Int32) -> String {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }
    #expect(heard(loud).contains("event.settings"))
    #expect(heard(quiet).isEmpty)
}
