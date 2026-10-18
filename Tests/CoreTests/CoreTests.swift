import Foundation
import Testing
@testable import Core

@Test func storeRoundTrip() throws {
    let s = try Store()
    let r = Repo(name: "demo", path: "/tmp/demo")
    try s.save(r)
    let w = Worktree(repoId: r.id, branch: "feat", path: "/tmp/w", note: "hi")
    try s.save(w)
    #expect(try s.repos() == [r])
    #expect(try s.worktree(w.id)?.note == "hi")
    try s.delete(r)
    #expect(try s.worktrees().isEmpty) // cascade
}

@Test func lineBufferSplitsAcrossChunks() {
    var b = LineBuffer()
    #expect(b.append(Data("{\"a\":".utf8)).isEmpty)
    let lines = b.append(Data("1}\n{\"b\":2}\nrest".utf8))
    #expect(lines.count == 2)
}

@Test func jsonValueRoundTrip() throws {
    let v = try JSONValue.from(RPCRequest(id: 1, method: "x", params: .object(["k": .string("v")])))
    #expect(v["method"]?.string == "x")
    #expect(v["params"]?["k"]?.string == "v")
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

@Test func ghosttyConfigParse() {
    let c = GhosttyConfig.parse("# comment\nbackground = #1e1e2e\nforeground=cdd6f4\nfont-family = \"JetBrains Mono\"\nfont-size = 14\npalette = 1=#f38ba8\n")
    #expect(c.background == "#1e1e2e" && c.foreground == "cdd6f4" && c.fontFamily == "JetBrains Mono" && c.fontSize == 14 && c.palette[1] == "#f38ba8")
    #expect(GhosttyConfig.rgb("#ff0000")! == (1, 0, 0))
}
