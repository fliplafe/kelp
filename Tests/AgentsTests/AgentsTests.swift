import Foundation
import Testing
import Core
@testable import Agents

@Test func heuristicWaitingVsDone() {
    let t0 = Date()
    var d = StatusDetector(manifest: .presets[0])
    d.output("\u{1B}[1mDo you want to proceed? [y/n]\u{1B}[0m", at: t0)
    #expect(d.status == .working)
    #expect(d.tick(at: t0.addingTimeInterval(1)) == .working)
    #expect(d.tick(at: t0.addingTimeInterval(4)) == .waiting)

    var e = StatusDetector(manifest: .presets[0])
    e.output("all done, 3 files changed", at: t0)
    #expect(e.tick(at: t0.addingTimeInterval(4)) == .done)
}

@Test func hooksOverrideHeuristics() {
    let t0 = Date()
    var d = StatusDetector(manifest: .presets[0])
    d.hook("working")
    d.output("whatever", at: t0)
    #expect(d.tick(at: t0.addingTimeInterval(60)) == .working)
    d.hook("done")
    #expect(d.status == .done)
}

@Test func manifestFilesOverridePresets() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONEncoder().encode(AgentManifest(id: "mine", name: "Mine", command: "mine-cli")).write(to: dir.appendingPathComponent("mine.json"))
    try Data("{bad".utf8).write(to: dir.appendingPathComponent("bad.json"))
    let all = AgentManifest.load(dir: dir)
    #expect(all.contains { $0.id == "mine" } && all.contains { $0.id == "claude" })
}

@Test func hooksSettingsIsValidJSON() throws {
    let v = try JSONDecoder().decode(JSONValue.self, from: Data(Hooks.settingsJSON().utf8))
    #expect(v["hooks"]?["Stop"] != nil)
}
