import Foundation
import Testing
import Core
@testable import KelpApp

private func folder(_ files: [String: String]) throws -> URL {
    _ = testHome
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("kx-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    for (name, text) in files { try text.write(to: d.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    return d
}

@MainActor @Test func templatesTakeFieldsAndQuoteThem() {
    let item = JSONValue.object(["name": .string("it's"), "n": .int(3), "pr": .object(["id": .int(7)])])
    #expect(ExtActions.expand("echo ${name}", item: item, quote: false) == "echo it's")
    #expect(ExtActions.expand("echo ${name}", item: item, quote: true) == "echo 'it'\\''s'")   // one shell word, quote closed and reopened
    #expect(ExtActions.expand("${pr.id}-${n}-${missing}", item: item, quote: false) == "7-3-")
    #expect(ExtActions.expand("no placeholders $ {x", item: item, quote: false) == "no placeholders $ {x")
}

@MainActor @Test func valuesPrintTheWayTheyRead() {
    #expect(ExtActions.text(.double(2)) == "2")
    #expect(ExtActions.text(.double(2.5)) == "2.5")
    #expect(ExtActions.text(.bool(true)) == "true")
    #expect(ExtActions.text(.null) == "")
}

@MainActor @Test func listOutputIsAnArrayOrOneObjectPerLine() {
    #expect(ExtListView.parse(#"[{"a":1},{"a":2}]"#).count == 2)
    #expect(ExtListView.parse("{\"a\":1}\n{\"a\":2}\nnot json\n").count == 2)   // a line that isn't JSON is skipped, not fatal
    #expect(ExtListView.parse("  \n").isEmpty)
}

@MainActor @Test func disabledListFallsBackToTheDefaultOnlyWhenUnset() {
    #expect(ExtensionRegistry.disabled(nil) == ExtensionRegistry.offByDefault)
    #expect(ExtensionRegistry.disabled(.array([.string("a"), .int(1)])) == ["a"])
    #expect(ExtensionRegistry.disabled(.array([])).isEmpty)   // an explicit empty list switches everything on
}

@MainActor @Test func aManifestFolderBecomesContributions() throws {
    let d = try folder(["extension.json": #"{"id":"t.one","name":"One","contributes":{"commands":[{"title":"Hi","terminal":"echo hi"}],"panels":[{"id":"p","title":"P","web":"p.html"}]}}"#])
    let (info, c) = DeclarativeExtension.load(d, checkRequirements: false)
    #expect(info.id == "t.one" && info.error == nil && info.unavailable == nil)
    #expect(c.commands.map(\.title) == ["Hi"])
    #expect(c.panels.map(\.id) == ["t.one.p"])
}

@MainActor @Test func aBrokenManifestIsReportedNotThrown() throws {
    let d = try folder(["extension.json": #"{"name":"no id"}"#])
    let (info, c) = DeclarativeExtension.load(d, checkRequirements: false)
    #expect(info.error != nil)
    #expect(info.id == d.lastPathComponent)   // still listed, so it can be fixed or removed
    #expect(c.commands.isEmpty && c.panels.isEmpty)
}

@MainActor @Test func missingRequirementKeepsTheExtensionInactive() throws {
    let d = try folder(["extension.json": #"{"id":"t.req","name":"R","requires":["kelp-no-such-tool"],"contributes":{"commands":[{"title":"X","run":"x"}]}}"#])
    let (info, c) = DeclarativeExtension.load(d)
    #expect(info.unavailable?.contains("kelp-no-such-tool") == true)
    #expect(c.commands.isEmpty)
}

@MainActor @Test func aVSCodePackageIsReadForItsIconThemes() throws {
    let d = try folder(["package.json": #"{"name":"icons","publisher":"me","displayName":"Icons","contributes":{"iconThemes":[{"id":"i","label":"I","path":"./i.json"}]}}"#])
    let (info, c) = DeclarativeExtension.load(d, checkRequirements: false)
    #expect(info.id == "me.icons" && info.name == "Icons")
    #expect(c.iconThemes.map(\.id) == ["i"])
}

@MainActor @Test func anExtensionIdThatIsntAPlainFolderNameIsRefused() {
    for bad in ["..", ".", "", "a/b", "../x", ".hidden"] { #expect(!ExtensionRegistry.isPlainName(bad), "\(bad.debugDescription)") }
    for ok in ["me.icons", "icons", "kelp-git"] { #expect(ExtensionRegistry.isPlainName(ok)) }
}
