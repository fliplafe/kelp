import Foundation
import Testing
import Core
@testable import Daemon

private func home() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ks-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func aFreshHomeStartsEmptyAndWritesTheFile() throws {
    let d = try home()
    let s = SettingsStore(root: d)
    #expect(s.all == .object([:]))
    #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("settings.json").path))
}

@Test func theOldConfigIsReadOnceWhenThereIsNoSettingsFileYet() throws {
    let d = try home()
    try #"{"hibernateMinutes":30,"keepAwake":"always","unknown":1}"#.write(to: d.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    let s = SettingsStore(root: d)
    #expect(s["sessions.hibernateMinutes"] == .int(30) && s["power.keepAwake"] == .string("always"))
    #expect(s["unknown"] == nil)   // only the keys that had a new home
    try #"{"hibernateMinutes":5}"#.write(to: d.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    #expect(SettingsStore(root: d)["sessions.hibernateMinutes"] == .int(30))   // settings.json exists now: config.json is not read again
}

@Test func setKeepsKeysAndNullRemovesThem() throws {
    let d = try home()
    let s = SettingsStore(root: d)
    _ = try s.set("editor.fontSize", .int(14)); _ = try s.set("theme", .string("nord"))
    #expect(s.number("editor.fontSize") == 14)
    _ = try s.set("editor.fontSize", .null)
    #expect(s["editor.fontSize"] == nil && s["theme"] == .string("nord"))
    #expect(SettingsStore(root: d)["theme"] == .string("nord"))   // it was written, not only held
}

@Test func numbersReadAsEitherIntOrDouble() throws {
    let s = SettingsStore(root: try home())
    _ = try s.set("a", .int(2)); _ = try s.set("b", .double(2.5)); _ = try s.set("c", .string("x"))
    #expect(s.number("a") == 2 && s.number("b") == 2.5 && s.number("c") == nil && s.number("missing") == nil)
}

@Test func aHandEditIsPickedUpButOurOwnWriteIsNot() throws {
    let d = try home()
    let s = SettingsStore(root: d)
    _ = try s.set("a", .int(1))
    #expect(!s.reloadIfChanged())   // we wrote that ourselves
    Thread.sleep(forTimeInterval: 0.05)
    try #"{"a": 2}"#.write(to: d.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: d.appendingPathComponent("settings.json").path)
    #expect(s.reloadIfChanged() && s["a"] == .int(2))
    #expect(!s.reloadIfChanged())   // nothing changed since
}

@Test func aFileThatDoesNotParseKeepsTheLastGoodSettings() throws {
    let d = try home()
    let s = SettingsStore(root: d)
    _ = try s.set("a", .int(1))
    let f = d.appendingPathComponent("settings.json")
    try "{ not json".write(to: f, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: f.path)
    #expect(!s.reloadIfChanged() && s["a"] == .int(1))
    try #"[1,2]"#.write(to: f, atomically: true, encoding: .utf8)   // valid JSON, wrong shape
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: f.path)
    #expect(!s.reloadIfChanged() && s["a"] == .int(1))
}

@Test func aChangeFromTheAppKeepsAHandEditMadeJustBefore() throws {
    let d = try home()
    let s = SettingsStore(root: d)
    _ = try s.set("a", .int(1))
    try #"{"a": 1, "byHand": true}"#.write(to: d.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)   // not polled yet
    _ = try s.set("b", .int(2))
    let back = SettingsStore(root: d)
    #expect(back["byHand"] == .bool(true) && back["b"] == .int(2) && back["a"] == .int(1))
}

@Test func aFileBeingEditedIsNeverOverwritten() throws {
    let d = try home()
    let s = SettingsStore(root: d)
    _ = try s.set("a", .int(1))
    let f = d.appendingPathComponent("settings.json")
    try "{ \"a\": 1, \"half-typed\": ".write(to: f, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { _ = try s.set("b", .int(2)) }
    #expect(try String(contentsOf: f, encoding: .utf8) == "{ \"a\": 1, \"half-typed\": ")   // the user's text is still there
}

@Test func settingsKeptInADotfilesRepoStayALink() throws {
    let d = try home(), dotfiles = try home()
    let real = dotfiles.appendingPathComponent("kelp-settings.json")
    try "{}".write(to: real, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("settings.json"), withDestinationURL: real)
    _ = try SettingsStore(root: d).set("theme", .string("nord"))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: d.appendingPathComponent("settings.json").path)) != nil)   // still a link
    #expect(try String(contentsOf: real, encoding: .utf8).contains("nord"))   // and the file it points at has the change
}
