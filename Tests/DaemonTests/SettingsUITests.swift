import Foundation
import Testing
import Core
@testable import Daemon

final class EventBox: @unchecked Sendable {
    private let l = NSLock(); private var events: [(String, JSONValue)] = []
    func add(_ m: String, _ p: JSONValue) { l.withLock { events.append((m, p)) } }
    func last(_ m: String) -> JSONValue? { l.withLock { events.last { $0.0 == m }?.1 } }
}

@Test func settingsMigrateSetAndHandEdit() async throws {
    let root = tmp()
    try #"{"hibernateMinutes":5,"keepAwake":"off","profiles":[{"name":"Work","agent":"claude","dir":"/x"}],"other":1}"#
        .write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let c = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
    let box = EventBox(); c.onNotification = { box.add($0, $1) }

    let s0 = try await c.call("settings.get")
    #expect(s0["sessions.hibernateMinutes"] == 5 && s0["power.keepAwake"] == "off" && s0["accounts.profiles"]?.array?.count == 1 && s0["other"] == nil)

    let s1 = try await c.call("settings.set", .obj(["key": "editor.fontSize", "value": 13]))
    #expect(s1["editor.fontSize"] == 13)
    let file = root.appendingPathComponent("settings.json")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == s1)
    let (a, e) = (try #require(text.range(of: "accounts.profiles")), try #require(text.range(of: "editor.fontSize")))
    #expect(text.contains("\n  ") && a.lowerBound < e.lowerBound)   // pretty-printed, sorted keys
    #expect(try await waitFor { box.last("event.settings")?["settings"] == s1 })
    #expect(try await c.call("settings.set", .obj(["key": "editor.fontSize"]))["editor.fontSize"] == nil)   // no value removes

    try #"{"theme": "dark"}"#.write(to: file, atomically: true, encoding: .utf8)   // a hand edit
    #expect(try await waitFor { box.last("event.settings")?["settings"] == .obj(["theme": "dark"]) })
    #expect(try await c.call("settings.get") == .obj(["theme": "dark"]))
    try "{ not json".write(to: file, atomically: true, encoding: .utf8)
    try await Task.sleep(for: .seconds(1))
    #expect(try await c.call("settings.get") == .obj(["theme": "dark"]))   // a broken file keeps the last good settings
}

@Test func uiRelayReachesTheApp() async throws {
    let root = tmp(); let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let sock = root.appendingPathComponent("kelp.sock").path
    let agent = try RPCClient(socket: sock)
    #expect(try await agent.call("ui.state") == .object([:]))
    await #expect(throws: RPCError.internalError("The Kelp app isn't running")) { try await agent.call("ui.open", .obj(["uri": "/a.swift"])) }

    let app = try RPCClient(socket: sock)
    let box = EventBox(); app.onNotification = { box.add($0, $1) }
    let state: JSONValue = .obj(["extensions": .array([.obj(["id": "git", "name": "Git", "enabled": true, "builtin": true])])])
    _ = try await app.call("ui.publish", .obj(["state": state]))
    #expect(try await agent.call("ui.state") == state)
    #expect(try await agent.call("ui.open", .obj(["uri": "file:///a.swift#L3", "split": "right"])) == .obj(["delivered": 1]))
    #expect(try await waitFor { box.last("event.ui") == .obj(["action": "open", "uri": "file:///a.swift#L3", "split": "right"]) })
    _ = try await agent.call("ui.command", .obj(["id": "extensions.reload"]))
    #expect(try await waitFor { box.last("event.ui") == .obj(["action": "command", "id": "extensions.reload"]) })
    await #expect(throws: RPCError.self) { try await agent.call("ui.open", .obj(["uri": "x", "split": "left"])) }

    app.close()   // the app quit: nothing to deliver to, nothing shown
    #expect(try await waitFor { (try? await agent.call("ui.open", .obj(["uri": "/a"]))) == nil })
    #expect(try await agent.call("ui.state") == .object([:]))
}
