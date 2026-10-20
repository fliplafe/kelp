import Foundation
import Core
import Testing
@testable import Daemon

@Test func ptyKillReportsExit() async throws {
    let box = Box()
    let p = try PTY(argv: ["/bin/zsh", "-lc", "echo ready; cat"], cwd: "/tmp", env: [:])
    p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
    p.onExit = { box.exit($0) }
    p.start()
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
    p.start()
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
        p.start()
        for _ in 0..<50 where !box.text.contains("ready") { try await Task.sleep(for: .milliseconds(100)) }
        pid = p.pid
        p.terminate()
    }
    for _ in 0..<50 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
    #expect(kill(pid, 0) != 0, "still there: stuck exiting on a terminal nobody reads")
}

/// Once its program has exited a PTY's fd (and pid) may be someone else's: typing into it reaches nobody.
@Test func endedPTYWritesNowhere() async throws {
    let box = Box()
    let p = try PTY(argv: ["/bin/sh", "-c", "exit 0"], cwd: "/tmp", env: [:])
    p.onExit = { box.exit($0) }
    p.start()
    for _ in 0..<50 where box.code == nil { try await Task.sleep(for: .milliseconds(100)) }
    #expect(box.code != nil)
    // The freed fd number goes to whatever opens next: socket pairs, so anything written to one end shows at the other.
    var pairs: [[Int32]] = []
    for _ in 0..<16 { var sv: [Int32] = [0, 0]; _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &sv); pairs.append(sv) }
    defer { pairs.joined().forEach { close($0) } }
    p.write(Data("typed-after-exit".utf8)); p.resize(cols: 10, rows: 10); p.kill()
    #expect(p.foregroundProgram == nil)
    var got = 0
    for fd in pairs.joined() {
        var b = [UInt8](repeating: 0, count: 64)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        if read(fd, &b, b.count) > 0 { got += 1 }
    }
    #expect(got == 0)
}

/// A shell running `sleep` is busy with it; at its prompt it is not (closing it would stop that program).
@Test func aShellRunningAProgramReportsItAsForeground() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let kelp = root.appendingPathComponent(".build/debug/kelp").path
    guard FileManager.default.isExecutableFile(atPath: kelp) else { return }   // `swift build` first
    let p = try PTY(argv: ["/bin/zsh", "-f", "-i"], cwd: "/tmp", env: [:], trampoline: kelp)   // job control needs the controlling terminal
    p.start()
    defer { p.kill() }
    try await Task.sleep(for: .seconds(1))
    #expect(p.foregroundProgram == nil)   // at the prompt
    p.write(Data("sleep 30\n".utf8))
    var seen: String?
    for _ in 0..<60 where seen == nil { try await Task.sleep(for: .milliseconds(100)); seen = p.foregroundProgram }
    #expect(seen == "sleep")
}
