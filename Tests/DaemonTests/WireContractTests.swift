import Foundation
import Testing
import Core
@testable import Daemon

/// The method names are the wire contract with the app, the CLI and people's scripts: adding one is fine (add it to
/// methods.txt), renaming or removing one breaks them. Params and results follow the same rule, checked by the tests that
/// call with hand-written JSON.
@Test func methodNamesOnlyGrow() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("methods.txt")
    let pinned = Set(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init))
    let served = Set(Daemon.typed.keys).union(Daemon.asyncTyped.keys)
    #expect(pinned.subtracting(served).sorted() == [], "renamed or removed: clients still send these")
    #expect(served.subtracting(pinned).sorted() == [], "new: add them to methods.txt")
}

/// The events' names are wire contract too (events.txt), and so are their params: an older app and people's scripts read
/// them as they always were.
@Test func eventNamesOnlyGrowAndKeepTheirShape() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("events.txt")
    let pinned = Set(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init))
    let sent = Set(rpcEvents.map { $0.name })
    #expect(pinned.subtracting(sent).sorted() == [], "renamed or removed: clients still listen for these")
    #expect(sent.subtracting(pinned).sorted() == [], "new: add them to events.txt")
    func wire(_ e: some RPCEvent) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Wire.line(RPCNotification(e))) }
    #expect(try wire(ChangedEvent.worktree) == .obj(["jsonrpc": "2.0", "method": "event.changed", "params": "worktree"]))
    #expect(try wire(OutputEvent(session: "s", data: Data("hi".utf8)))["params"] == .obj(["session": "s", "data": "aGk="]))
    #expect(try wire(SettingsEvent(settings: ["a": 1]))["params"] == .obj(["settings": .obj(["a": 1])]))
    #expect(try wire(UIEvent(UIOpen(uri: "file:///x", split: "right")))["params"] == .obj(["action": "open", "uri": "file:///x", "split": "right"]))
}
