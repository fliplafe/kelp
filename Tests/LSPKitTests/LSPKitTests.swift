import Foundation
import Testing
import Core
@testable import LSPKit

@Test func framerHandlesSplitAndMultipleMessages() {
    let a = LSPFramer.frame(Data(#"{"a":1}"#.utf8)), b = LSPFramer.frame(Data(#"{"b":2}"#.utf8))
    var f = LSPFramer()
    let all = a + b
    #expect(f.append(all.prefix(10)).isEmpty)
    let out = f.append(all.dropFirst(10))
    #expect(out.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
}

@Test func framerSkipsBadLengths() {
    var f = LSPFramer()
    let bad = Data("Content-Length: -5\r\n\r\n".utf8) + LSPFramer.frame(Data(#"{"a":1}"#.utf8))
    #expect(f.append(bad).map { String(bytes: $0, encoding: .utf8) } == [#"{"a":1}"#])
}

@Test func requestsFailOnceTheServerExited() async throws {
    let c = try #require(LSPClient(argv: ["/usr/bin/true"], root: NSTemporaryDirectory()))
    for _ in 0..<100 where c.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!c.isRunning)
    await #expect(throws: RPCError.self) { _ = try await c.request("initialize", .null) }
}

@Test func silentServerTimesOut() async throws {
    let c = try #require(LSPClient(argv: ["/bin/sleep", "30"], root: NSTemporaryDirectory()))
    await #expect(throws: RPCError.self) { _ = try await c.request("initialize", .null, timeout: 0.2) }
    c.terminate()
}

@Test func documentsAreSharedByTabs() throws {
    let c = try #require(LSPClient(argv: ["/bin/cat"], root: NSTemporaryDirectory()))
    let idle = DiagBox()
    c.onIdle = { idle.set("", [Diagnostic(line: 1, column: 1, severity: 1, message: "")]) }
    c.open("/x.swift", text: "", languageId: "swift"); c.open("/x.swift", text: "", languageId: "swift")
    c.close("/x.swift")
    #expect(c.openDocuments == ["/x.swift": 1] && idle.count == 0)
    c.close("/x.swift")
    #expect(c.isIdle && idle.count == 1)
    c.close("/x.swift")   // not open: nothing to close
    c.terminate()
}

@Test func sourcekitDiagnosticsAndDefinition() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lsp-\(UUID().uuidString.prefix(6))").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let file = dir + "/main.swift"
    let text = "func greet() -> Int { 1 }\nlet x: String = greet()\n"
    try text.write(toFile: file, atomically: true, encoding: .utf8)
    guard let c = LSPClient(argv: ["xcrun", "sourcekit-lsp"], root: dir) else { return }
    let got = DiagBox()
    c.onDiagnostics = { p, d in got.set(p, d) }
    try await c.initialize()
    c.open(file, text: text, languageId: "swift")
    let loc = try await c.definition(file, line: 2, column: 18)
    #expect(loc?.line == 1)
    for _ in 0..<100 where got.count == 0 { try await Task.sleep(for: .milliseconds(100)) }
    #expect(got.count > 0)   // Int is not String
    c.shutdown()
}

final class DiagBox: @unchecked Sendable {
    private let l = NSLock(); private var d: [Diagnostic] = []
    func set(_ p: String, _ x: [Diagnostic]) { l.lock(); d = x; l.unlock() }
    var count: Int { l.lock(); defer { l.unlock() }; return d.count }
}

@Test func symbolAroundALine() throws {
    func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
    func range(_ a: Int, _ b: Int) -> String { #"{"start":{"line":\#(a),"character":0},"end":{"line":\#(b),"character":0}}"# }
    // class TestParse (lines 1-9) > def test_empty (3-5) > local x (4); def helper (11-12)
    let tree = try json(#"""
    [{"name":"TestParse","kind":5,"range":\#(range(0, 8)),"children":[
       {"name":"test_empty","kind":6,"range":\#(range(2, 4)),"children":[{"name":"x","kind":13,"range":\#(range(3, 3))}]}]},
     {"name":"helper","kind":12,"range":\#(range(10, 11))}]
    """#)
    #expect(LSPClient.enclosingSymbol(tree, line: 4) == "test_empty")   // not the variable x
    #expect(LSPClient.enclosingSymbol(tree, line: 2) == "TestParse")
    #expect(LSPClient.enclosingSymbol(tree, line: 12) == "helper")
    #expect(LSPClient.enclosingSymbol(tree, line: 10) == nil)
    let flat = try json(#"[{"name":"TestFoo","kind":12,"location":{"uri":"file:///a.go","range":\#(range(4, 9))}}]"#)
    #expect(LSPClient.enclosingSymbol(flat, line: 6) == "TestFoo")
    #expect(LSPClient.enclosingSymbol(.null, line: 6) == nil)
}
