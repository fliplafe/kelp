import AppKit
import Foundation
import Testing
import Core
import WorkbenchKit
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
    #expect(ExtActions.expand("echo ${name}", item: item, quote: true) == #"KELP_V1='it'\''s'; echo "${KELP_V1}""#)   // a variable, not text
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
    let d = try folder(["extension.json":
        #"{"id":"t.one","name":"One","contributes":{"commands":[{"title":"Hi","terminal":"echo hi"}],"panels":[{"id":"p","title":"P","web":"p.html"}]}}"#])
    let (info, c) = DeclarativeExtension.load(d)
    #expect(info.id == "t.one" && info.error == nil && info.unavailable == nil)
    #expect(c.commands.map(\.title) == ["Hi"])
    #expect(c.panels.map(\.id) == ["t.one.p"])
}

@MainActor @Test func aBrokenManifestIsReportedNotThrown() throws {
    let d = try folder(["extension.json": #"{"name":"no id"}"#])
    let (info, c) = DeclarativeExtension.load(d)
    #expect(info.error != nil)
    #expect(info.id == d.lastPathComponent)   // still listed, so it can be fixed or removed
    #expect(c.commands.isEmpty && c.panels.isEmpty)
}

@MainActor @Test func missingRequirementKeepsTheExtensionInactive() throws {
    let d = try folder(["extension.json": #"{"id":"t.req","name":"R","requires":["kelp-no-such-tool"],"contributes":{"commands":[{"title":"X","run":"x"}]}}"#])
    let (info, c) = DeclarativeExtension.load(d, tools: ["kelp-no-such-tool": false])
    #expect(info.unavailable?.contains("kelp-no-such-tool") == true)
    #expect(c.commands.isEmpty)
    // Until the daemon has said (it may still be reading the login shell's PATH), a tool counts as there.
    #expect(DeclarativeExtension.load(d).info.unavailable == nil)
}

@MainActor @Test func aVSCodePackageIsReadForItsIconThemes() throws {
    let d = try folder(["package.json": #"{"name":"icons","publisher":"me","displayName":"Icons","contributes":{"iconThemes":[{"id":"i","label":"I","path":"./i.json"}]}}"#])
    let (info, c) = DeclarativeExtension.load(d)
    #expect(info.id == "me.icons" && info.name == "Icons")
    #expect(c.iconThemes.map(\.id) == ["i"])
}

/// An action's command takes item fields as variables: a title with $(…) or a newline never runs (all the quoting
/// cases are in WorkbenchKitTests.aValueInAShellTemplateNeverRuns).
extension SharedAppModel {
@Test func aFieldNeverRunsInAnActionsCommand() async throws {
    let rig = try await AppRig(files: [:]); defer { rig.done() }   // the daemon runs it
    let marker = NSTemporaryDirectory() + "kelp-pwned-\(UUID().uuidString.prefix(6))"
    let evil = "a\ntouch \(marker)\n$(touch \(marker)) end"
    let cmd = ExtActions.expand(#"printf %s "${title}""#, item: .object(["title": .string(evil)]), quote: true)
    let r = await Shell.run(cmd, cwd: NSTemporaryDirectory())
    #expect(r.code == 0 && !FileManager.default.fileExists(atPath: marker) && r.stdout == evil)
}
}

/// A tab's own items in its context menu come from its provider (an agent's, a file's); a tab whose provider adds none
/// gets the shell's alone.
extension SharedAppModel {
    @Test func aTabsMenuHasWhatItsProviderAdds() {
        _ = testHome; _ = NSApplication.shared   // reload applies the theme to NSApp
        ExtensionRegistry.shared.reload()
        let area = EditorArea(app: AppModel.shared, workspaceId: "menu-test")
        let agent = area.layout.add("session:s1"), page = area.layout.add(TabURI.file("/tmp/a.html")), web = area.layout.add("https://example.com")
        func titles(_ id: String) -> [String] { area.tabMenu(id).items.map { $0.isSeparatorItem ? "-" : $0.title } }
        let around = (["Split Right", "Split Down", "-"], ["Close Tab", "Close Other Tabs"])
        #expect(titles(agent.id) == around.0 + ["Rename…", "Restart", "Copy Context", "Hand Off to", "Changes in Its Last Turn", "-"] + around.1)
        #expect(titles(page.id) == around.0 + ["Reveal in Finder", "Copy Path", "Copy Web Link", "Send to Agent", "Open Preview to the Side", "-"] + around.1)
        #expect(titles(web.id) == around.0 + around.1)
    }
}
