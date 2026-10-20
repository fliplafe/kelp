import Foundation
import Testing
import WorkbenchKit

@Test func addPutsTabsInTheFocusedGroup() throws {
    var l = WorkspaceLayout()
    let a = l.add("session:a")   // the first tab makes the first group
    let g = try #require(l.focused)
    let b = l.add("file:///x")
    let c = l.add("file:///y", to: g, at: 0)
    #expect(l.root == .pane(g))
    #expect(l.groups[g]?.tabs == [c, a, b])
    #expect(l.focusedGroup?.selectedTab == c)
    #expect(l.tab(uri: "file:///x") == b)
}

@Test func splitMovesATabIntoANewGroupBeside() throws {
    var l = WorkspaceLayout()
    let a = l.add("a"), b = l.add("b")
    let g = try #require(l.focused)
    l.split(b.id, from: g, vertical: true, before: false)
    let h = try #require(l.group(of: b.id))
    #expect(h != g && l.focused == h)
    #expect(l.root == .split(vertical: true, children: [.pane(g), .pane(h)]))
    #expect(l.groups[g]?.tabs == [a])
    // A group's only tab split off that same group changes nothing.
    let before = l
    l.split(b.id, from: h, vertical: false, before: true)
    #expect(l == before)
}

@Test func edgeDropSpansTheWholeSide() throws {
    var l = WorkspaceLayout()
    _ = l.add("a")
    let b = l.add("b")
    let g = try #require(l.focused)
    l.split(b.id, from: g, vertical: true, before: false)
    let h = try #require(l.focused)
    let c = l.add("c", to: h)
    l.splitRoot(c.id, vertical: false, before: false)
    let k = try #require(l.group(of: c.id))
    #expect(l.root == .split(vertical: false, children: [.split(vertical: true, children: [.pane(g), .pane(h)]), .pane(k)]))
}

@Test func movingTheLastTabOutRemovesItsGroup() throws {
    var l = WorkspaceLayout()
    let a = l.add("a"), b = l.add("b")
    let g = try #require(l.focused)
    l.split(b.id, from: g, vertical: true, before: false)
    let h = try #require(l.focused)
    l.move(a.id, to: h, index: 0)
    #expect(l.groups[g] == nil)
    #expect(l.root == .pane(h))
    #expect(l.groups[h]?.tabs == [a, b])
    #expect(l.groups[h]?.selected == a.id && l.focused == h)
}

@Test func closingTabsCollapsesSplitsButKeepsTheLastGroup() throws {
    var l = WorkspaceLayout()
    let a = l.add("a"), b = l.add("b"), c = l.add("c")
    let g = try #require(l.focused)
    l.select(b.id)
    l.remove(b.id)
    #expect(l.groups[g]?.selected == c.id)   // the neighbour that took its place
    l.split(c.id, from: g, vertical: false, before: false)
    let h = try #require(l.focused)
    l.remove(c.id)
    #expect(l.groups[h] == nil)
    #expect(l.root == .pane(g) && l.focused == g)
    l.remove(a.id)
    #expect(l.root == .pane(g) && l.allTabs.isEmpty)
}

@Test func fileURIsRoundTrip() {
    let u = TabURI.file("/tmp/my dir/a.swift", line: 12)
    #expect(u == "file:///tmp/my%20dir/a.swift#L12")
    #expect(TabURI.scheme(u) == "file")
    let (path, line) = TabURI.filePath(u)
    #expect(path == "/tmp/my dir/a.swift" && line == 12)
    #expect(TabURI.filePath("/tmp/x").line == nil)
    #expect(TabURI.body("ext:my.ext/view") == "my.ext/view")
}

@Test func normalizeTakesWhatPeopleType() {
    #expect(TabURI.normalize("Sources/a.swift:12", cwd: "/repo") == "file:///repo/Sources/a.swift#L12")
    #expect(TabURI.normalize("/abs/b.swift", cwd: "/repo") == "file:///abs/b.swift")
    #expect(TabURI.normalize("localhost:3000", cwd: "/repo") == "http://localhost:3000")
    #expect(TabURI.normalize("https://x.dev/a:1", cwd: "/repo") == "https://x.dev/a:1")
    #expect(TabURI.normalize("session:abc", cwd: "/repo") == "session:abc")
}

@Test func keySpecsParseAndFormat() throws {
    #expect(KeySpec("cmd+shift+k") == KeySpec(key: "K", mods: [.command, .shift]))
    #expect(KeySpec("Command+Alt+S") == KeySpec(key: "s", mods: [.command, .option]))
    #expect(KeySpec("opt+cmd+return")?.key == "\r")
    #expect(KeySpec("ctrl+up")?.key == "\u{F700}")
    #expect(KeySpec("cmd+plus")?.key == "+")
    #expect(KeySpec("cmd+") == nil)
    for s in ["shift+cmd+k", "opt+cmd+return", "ctrl+up", "shift+cmd+plus", "ctrl+opt+shift+cmd+left", "cmd+1", "esc"] {
        #expect(KeySpec(s)?.description == s)
    }
    #expect(KeySpec(key: "\u{7f}", mods: [.command]).description == "cmd+delete")
}

@Test func layoutSplitMoveRemove() {
    var l = LayoutNode.pane("a")
    l = l.inserting("b", beside: "a", vertical: true, before: false)
    l = l.inserting("c", beside: "b", vertical: false, before: false)
    #expect(l.sessions == ["a", "b", "c"])
    let moved = l.removing("c")!.inserting("c", beside: "a", vertical: true, before: true)
    #expect(moved.sessions == ["c", "a", "b"])
    #expect(LayoutNode.pane("a").removing("a") == nil)
    #expect(l.removing("a")?.removing("b")?.removing("c") == nil)
    #expect(l.neighbor(of: "c", step: 1) == "a")
}

/// Divider positions are kept per split: the key survives tab changes and changes when the split gets another pane.
@Test func layoutSplitKeys() {
    let l = LayoutNode.pane("a").inserting("b", beside: "a", vertical: true, before: false).inserting("c", beside: "b", vertical: false, before: false)
    #expect(l.splitKeys == ["a,b", "b,c"])
    #expect(LayoutNode.pane("a").splitKeys.isEmpty)
    #expect(l.removing("c")?.splitKeys == ["a,b"])
}

@Test func languageForAPath() throws {
    let json = #"""
    [{ "id": "python", "extensions": ["py"],
       "server": { "command": "pyright-langserver", "args": ["--stdio"], "install": "npm i -g pyright" } },
     { "id": "dockerfile", "extensions": [], "fileNames": ["Dockerfile"] }]
    """#
    let specs = try JSONDecoder().decode([LanguageSpec].self, from: Data(json.utf8))
    #expect(specs[0] == LanguageSpec(id: "python", extensions: ["py"],
                                     server: .init(command: "pyright-langserver", args: ["--stdio"], install: "npm i -g pyright")))
    #expect(LanguageSpec.find("/a/b/main.PY", in: specs)?.id == "python")
    #expect(LanguageSpec.find("/a/Dockerfile", in: specs)?.id == "dockerfile")
    #expect(LanguageSpec.find("/a/b/main.rb", in: specs) == nil)
    #expect(LanguageSpec.find("/a/b/Makefile", in: specs) == nil)
    // A later language with the same id replaces the earlier one, files and server.
    let mine = LanguageSpec(id: "python", extensions: ["pyi"], server: .init(command: "pylsp"))
    #expect(LanguageSpec.find("x.pyi", in: specs + [mine])?.server?.command == "pylsp")
    #expect(LanguageSpec.find("x.py", in: specs + [mine]) == nil)
}
