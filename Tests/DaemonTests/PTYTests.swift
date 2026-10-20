import Foundation
import Core
import Testing
@testable import Daemon

@Test func ptyKillReportsExit() async throws {
    let box = Box()
    let p = try PTY(argv: ["/bin/sh", "-c", "echo ready; cat"], cwd: "/tmp", env: [:])   // not a login shell: no profile of the user's runs
    p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
    p.onExit = { box.exit($0) }
    p.start()
    #expect(try await waitFor(10) { box.text.contains("ready") })
    p.kill()
    #expect(try await waitFor(10) { box.code != nil })
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
    try #require(FileManager.default.isExecutableFile(atPath: kelp), "build the kelp CLI first: swift build")
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
    for _ in 0..<100 where !box.text.contains("20 50") { try await Task.sleep(for: .milliseconds(50)) }   // a busy machine is slow, not wrong
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
    try #require(FileManager.default.isExecutableFile(atPath: kelp), "build the kelp CLI first: swift build")
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
    try #require(FileManager.default.isExecutableFile(atPath: kelp), "build the kelp CLI first: swift build")
    let box = Box()
    let p = try PTY(argv: ["/bin/zsh", "-f", "-i"], cwd: "/tmp", env: [:], trampoline: kelp)   // job control needs the controlling terminal
    p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
    p.start()
    defer { p.kill() }
    #expect(try await waitFor(10) { box.text.contains("%") })   // its prompt is drawn
    #expect(p.foregroundProgram == nil)   // at the prompt
    p.write(Data("sleep 30\n".utf8))
    var seen: String?
    for _ in 0..<200 where seen == nil { try await Task.sleep(for: .milliseconds(100)); seen = p.foregroundProgram }   // up to 20 s on a loaded machine
    #expect(seen == "sleep")
}

@Test func aTerminalThatCantBeOpenedYetIsRetriedButOtherErrorsAreNot() throws {
    var calls = 0
    let ok = try PTY.retrying { () throws -> String in
        calls += 1
        if calls < 3 { throw PTYError(step: "spawn", code: EIO) }
        return "started"
    }
    #expect(ok == "started" && calls == 3)   // two refusals, then it worked
    calls = 0
    #expect(throws: PTYError.self) { try PTY.retrying { () throws -> Int in calls += 1; throw PTYError(step: "spawn", code: ENOENT) } }
    #expect(calls == 1)                      // a missing program won't appear by trying again
    calls = 0
    _ = try PTY.retrying { () throws -> Int in calls += 1; if calls < 2 { throw PTYError(step: "openpty", code: ENXIO) }; return 1 }
    #expect(calls == 2)                      // openpty's own transient refusal is retried too
    calls = 0
    #expect(throws: PTYError.self) { try PTY.retrying(attempts: 3) { () throws -> Int in calls += 1; throw PTYError(step: "spawn", code: EIO) } }
    #expect(calls == 3)                      // and it gives up in the end, with the real error
}

@Test func theErrorSaysWhichStepFailed() {
    let e = PTYError(step: "openpty", code: EMFILE)
    #expect(e.description.contains("openpty") && e.description.contains("errno \(EMFILE)"))
    #expect(e.localizedDescription == e.description)   // what the app shows, not "The operation couldn't be completed"
}

@Test func theProgramBeingStartedThatDoesntExistFailsWithAClearError() {
    #expect(throws: PTYError.self) { _ = try PTY(argv: ["/definitely/not/a/program"], cwd: "/tmp", env: [:], trampoline: nil) }
}

/// `daemon.shutdown` ends the process, so it is tried on a real `kelpd` of its own.
@Test func shutdownStopsTheDaemonProcessAndRemovesItsSocket() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let kelpd = root.appendingPathComponent(".build/debug/kelpd").path
    try #require(FileManager.default.isExecutableFile(atPath: kelpd), "build kelpd first: swift build")
    let home = tmp()
    let p = Process(); p.executableURL = URL(fileURLWithPath: kelpd)
    var env = ProcessInfo.processInfo.environment; env["KELP_HOME"] = home.path; p.environment = env
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run()
    defer { if p.isRunning { p.terminate() } }   // only the daemon this test started
    let sock = home.appendingPathComponent("kelp.sock").path
    #expect(try await waitFor(10) { FileManager.default.fileExists(atPath: sock) })
    let c = try RPCClient(socket: sock)
    #expect(try await c.call("ping").string == "pong")
    _ = try await c.call("daemon.shutdown")
    #expect(try await waitFor(10) { !p.isRunning })
    #expect(p.terminationStatus == 0)   // a clean exit, not a crash
}

/// A paste into a program that isn't reading (a build in the foreground) holds up nothing: not the caller (a connection's
/// reader thread), not the questions the app asks about the terminal.
@Test func writingToAProgramThatIsntReadingBlocksNothing() throws {
    let box = Box()
    let p = try PTY(argv: ["/bin/sh", "-c", "stty raw -echo; echo ready; sleep 30"], cwd: "/tmp", env: [:])   // raw, like a TUI: input queues up
    p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
    p.start()
    defer { p.kill() }
    for _ in 0..<100 where !box.text.contains("ready") { usleep(20_000) }
    let big = Data(repeating: 0x61, count: 2 << 20)   // far more than the terminal buffers
    let t = Date()
    p.write(big)
    #expect(Date().timeIntervalSince(t) < 0.2)       // queued, not written here
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { _ = p.size; _ = p.foregroundProgram; done.signal() }   // its own thread: a busy pool mustn't look like a stuck lock
    #expect(done.wait(timeout: .now() + 2) == .success, "size / foregroundProgram waited on the stuck write")
}

/// A terminal closes its fds once: finishing and being dropped both hang up, and a second close would hit a reused number.
@Test func aFinishedTerminalClosesItsFdsOnce() async throws {
    for _ in 0..<20 {
        let p = try PTY(argv: ["/bin/sh", "-c", "exit 0"], cwd: "/tmp", env: [:])
        let ended = Box()
        p.onExit = { ended.exit($0) }
        p.start()
        #expect(try await waitFor(5) { ended.code != nil })
        withExtendedLifetime(p) {}   // alive until it finished (Swift may release it right after its last use)
    }   // each is dropped here: deinit after finish
    // A pipe opened now gets one of the freed numbers; it must still work after any late close.
    let pipe = Pipe()
    try await Task.sleep(for: .milliseconds(200))
    pipe.fileHandleForWriting.write(Data("ok".utf8))
    try pipe.fileHandleForWriting.close()
    #expect(pipe.fileHandleForReading.readDataToEndOfFile() == Data("ok".utf8))
}
