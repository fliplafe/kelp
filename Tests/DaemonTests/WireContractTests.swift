import Foundation
import Testing
@testable import Daemon

/// The method names are the wire contract with the app, the CLI and people's scripts: adding one is fine (add it to
/// methods.txt), renaming or removing one breaks them. Params and results follow the same rule, checked by the tests that
/// call with hand-written JSON.
@Test func methodNamesOnlyGrow() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("methods.txt")
    let pinned = Set(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init))
    let served = Set(Daemon.typed.keys).union(Daemon.asyncTyped.keys)
    #expect(pinned.subtracting(served).sorted() == [], "renamed or removed: clients still send these")
    #expect(served.subtracting(pinned).sorted() == [], "new: add them to methods.txt")
}
