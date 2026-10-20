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
