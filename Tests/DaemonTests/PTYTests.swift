import Foundation
import Testing
@testable import Daemon

@Test func ptyKillReportsExit() async throws {
    let box = Box()
    let p = try PTY(argv: ["/bin/zsh", "-lc", "echo ready; cat"], cwd: "/tmp", env: [:])
    p.onOutput = { box.add(String(decoding: $0, as: UTF8.self)) }
    p.onExit = { box.exit($0) }
    try await Task.sleep(for: .milliseconds(500))
    #expect(box.text.contains("ready"))
    p.kill()
    try await Task.sleep(for: .seconds(1))
    #expect(box.code != nil)
}
final class Box: @unchecked Sendable {
    let l = NSLock(); var t = ""; var c: Int32?
    func add(_ s: String) { l.lock(); t += s; l.unlock() }
    func exit(_ x: Int32) { l.lock(); c = x; l.unlock() }
    var text: String { l.lock(); defer { l.unlock() }; return t }
    var code: Int32? { l.lock(); defer { l.unlock() }; return c }
}
