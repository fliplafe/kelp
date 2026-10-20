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
    let kelp = root.appendingPathComponent(".build/debug/kelp").path
    guard FileManager.default.isExecutableFile(atPath: kelp) else { return }   // `swift build` first
    let box = Box()
    let p = try PTY(argv: ["/bin/sh", "-c", "trap 'stty size; exit' WINCH; echo ready tty=$(ps -o tty= -p $$) size=$(stty size); while :; do sleep 0.1; done"], cwd: "/tmp", env: [:], cols: 100, rows: 30, trampoline: kelp)
    p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
    // Wait for the child rather than a fixed time: a busy machine (parallel builds) starts it late.
    for _ in 0..<50 where !box.text.contains("ready") { try await Task.sleep(for: .milliseconds(100)) }
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
    #expect(throws: RPCError.self) { try LoginPath.resolve("kelp-no-such-agent-cli") }
}

/// The limits probe drops its PTY right after signalling the agent, which still writes as it quits. As the terminal's
/// controlling process it then waits in exit for that output to be read, and nobody read it any more: it hung there
/// for good, each one holding a PTY until the daemon ran out of file descriptors.
@Test func droppedPTYLetsItsProgramExit() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let kelp = root.appendingPathComponent(".build/debug/kelp").path
    guard FileManager.default.isExecutableFile(atPath: kelp) else { return }   // `swift build` first
    let pid: pid_t
    do {
        let box = Box()
        let p = try PTY(argv: ["/bin/sh", "-c", "trap 'echo bye; exit 0' TERM HUP; echo ready; while :; do sleep 0.1; done"],
                        cwd: "/tmp", env: [:], trampoline: kelp)
        p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
        for _ in 0..<50 where !box.text.contains("ready") { try await Task.sleep(for: .milliseconds(100)) }
        pid = p.pid
        p.terminate()
    }
    for _ in 0..<50 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
    #expect(kill(pid, 0) != 0, "still there: stuck exiting on a terminal nobody reads")
}
