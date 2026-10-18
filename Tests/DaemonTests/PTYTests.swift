import Foundation
import Core
import Testing
@testable import Daemon

@Test func ptyKillReportsExit() async throws {
    let box = Box()
    let p = try PTY(argv: ["/bin/zsh", "-lc", "echo ready; cat"], cwd: "/tmp", env: [:])
    p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
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

/// Agents must own the PTY as controlling terminal, or resizes (SIGWINCH) never reach them.
@Test func resizeReachesChild() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let krill = root.appendingPathComponent(".build/debug/krill").path
    guard FileManager.default.isExecutableFile(atPath: krill) else { return }   // `swift build` first
    let box = Box()
    let p = try PTY(argv: ["/bin/sh", "-c", "trap 'stty size; exit' WINCH; echo ready tty=$(ps -o tty= -p $$) size=$(stty size); while :; do sleep 0.1; done"], cwd: "/tmp", env: [:], cols: 100, rows: 30, trampoline: krill)
    p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
    try await Task.sleep(for: .milliseconds(400))
    #expect(box.text.contains("ready"))
    #expect(!box.text.contains("tty=??"), "no controlling terminal: \(box.text.debugDescription)")
    #expect(box.text.contains("size=30 100"), "initial size lost: \(box.text.debugDescription)")
    p.resize(cols: 50, rows: 20)
    try await Task.sleep(for: .milliseconds(600))
    #expect(box.text.contains("20 50"), "\(box.text.debugDescription)")
    p.kill()
}

/// Agents are found on the login-shell PATH even when the daemon itself started with a bare one (from Finder).
@Test func loginPathFindsToolsAndExplainsMisses() throws {
    #expect(try LoginPath.resolve("git").hasSuffix("/git"))
    #expect(throws: RPCError.self) { try LoginPath.resolve("krill-no-such-agent-cli") }
}
