import AppKit
import Foundation
import Testing
import Core
import Daemon
@testable import KelpApp

/// Settings as the app and everything else share them: a change made in the app lands in settings.json through the
/// daemon, and one made elsewhere (`kelp settings set`, an agent) shows in the app without a restart.
extension SharedAppModel {
    @Test func settingsGoBothWaysThroughTheDaemon() async throws {
        _ = testHome
        _ = NSApplication.shared   // the theme applies to NSApp
        let root = URL(fileURLWithPath: "/tmp/kst-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try Daemon(root: root); try d.start(); defer { d.stop() }
        let app = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        let cli = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        let m = AppModel.shared, s = SettingsStore.shared
        let saved = (m.client, s.values)
        defer { m.client = saved.0; s.apply(saved.1) }
        m.client = app; m.listen(app)
        await s.load()

        s.set("editor.autoSave", .bool(true))   // in the app
        let file = root.appendingPathComponent("settings.json")
        func onDisk() -> JSONValue? { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
        for _ in 0..<100 where onDisk()?["editor.autoSave"]?.bool != true { try await Task.sleep(for: .milliseconds(50)) }
        #expect(onDisk()?["editor.autoSave"]?.bool == true)

        _ = try await cli.call("settings.set", .obj(["key": "editor.lsp", "value": false]))   // elsewhere
        for _ in 0..<100 where s.bool("editor.lsp") != false { try await Task.sleep(for: .milliseconds(50)) }
        #expect(s.bool("editor.lsp") == false && s.bool("editor.autoSave") == true)
    }
}
