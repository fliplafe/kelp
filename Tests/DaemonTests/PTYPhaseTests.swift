import Foundation
import Testing
@testable import Daemon

/// A terminal's phases go one way: waiting → reading → handed over or hung up; its program running → handed over or
/// reaped. Nothing comes back from an end.
@Test func aTerminalHandedOverStaysHandedOver() throws {
    let p = try PTY(argv: ["/bin/sh", "-c", "cat"], cwd: "/tmp", env: [:])
    #expect(p.phases.terminal == .waiting && p.phases.program == .running)
    p.start()
    #expect(p.phases.terminal == .reading)
    let fd = try #require(p.handOver())
    defer { kill(p.pid, SIGKILL); close(fd) }
    #expect(p.phases.terminal == .handedOver && p.phases.program == .handedOver)
    #expect(p.handOver() == nil)   // once
    p.start()
    #expect(p.phases.terminal == .handedOver)   // and never read here again
}

@Test func aTerminalWhoseProgramEndedIsHungUpAndReaped() async throws {
    let p = try PTY(argv: ["/bin/sh", "-c", "exit 3"], cwd: "/tmp", env: [:])
    let box = Box()
    p.onExit = { box.exit($0) }
    p.start()
    #expect(try await waitFor(10) { box.code != nil })
    #expect(p.phases.terminal == .hungUp && p.phases.program == .reaped)
    #expect(p.handOver() == nil && p.tree().isEmpty)
}

/// A program that let go of its terminal (its output ended) but runs on is still handed over: left out, it would run
/// on unseen, its record "working".
@Test func aProgramThatLetGoOfItsTerminalIsStillHandedOver() async throws {
    let p = try PTY(argv: ["/bin/sh", "-c", "exec </dev/null >/dev/null 2>&1; sleep 30"], cwd: "/tmp", env: [:], trampoline: nil)
    p.start()
    try await Task.sleep(for: .milliseconds(500))
    let fd = try #require(p.handOver())
    kill(p.pid, SIGKILL); close(fd)
}
