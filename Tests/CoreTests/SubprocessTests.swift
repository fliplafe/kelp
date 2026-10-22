import Foundation
import Testing
@testable import Core
import TestSupport

private let env = ProcessInfo.processInfo.environment

/// A big input and a big output at once don't block each other (stdin is written alongside the reads).
@Test func aSubprocessTakesAndGivesMoreThanAPipeHolds() throws {
    let text = Data(String(repeating: "line of text\n", count: 100_000).utf8)   // 1.3 MB each way
    let r = try Subprocess.run(["/bin/cat"], cwd: "/tmp", env: env, stdin: text, timeLimit: 30)
    #expect(r.status == 0 && !r.timedOut && r.stdout == text)
}

/// Past its time limit a program is stopped with what it started, even both ignoring SIGTERM.
@Test func aSubprocessPastItsLimitStopsWithItsChildren() throws {
    let pidFile = NSTemporaryDirectory() + "sp-\(UUID().uuidString)"
    let script = "trap '' TERM; (trap '' TERM; while :; do sleep 0.1; done) & echo $! > \(pidFile); wait"
    let start = Date()
    let r = try Subprocess.run(["/bin/bash", "-c", script], cwd: "/tmp", env: env, timeLimit: 0.5)
    #expect(r.timedOut && Date().timeIntervalSince(start) < 6)
    let child = try #require(pid_t((try String(contentsOfFile: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(child, SIGKILL) }
    let deadline = Date().addingTimeInterval(5)
    while kill(child, 0) == 0, Date() < deadline { usleep(50_000) }
    #expect(kill(child, 0) != 0)
}

/// A child left running with the pipes open (a daemon it started) doesn't hold up the result.
@Test func aSubprocessDoesntWaitForAChildHoldingItsPipes() throws {
    let pidFile = NSTemporaryDirectory() + "sp-\(UUID().uuidString)"
    let start = Date()
    let r = try Subprocess.run(["/bin/bash", "-c", "echo hi; sleep 30 & echo $! > \(pidFile)"], cwd: "/tmp", env: env, timeLimit: 30)
    if let child = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
        kill(child, SIGKILL)
    }
    #expect(r.status == 0 && String(decoding: r.stdout, as: UTF8.self) == "hi\n")
    #expect(Date().timeIntervalSince(start) < 10)
}

/// Past its limit a stream is still read, so the program runs to its end (its status is its own), but only the first
/// `limit` bytes are kept, and the output says it's cut.
@Test func aSubprocessKeepsItsLimitAndRunsToTheEnd() throws {
    let r = try Subprocess.run(["/bin/sh", "-c", "head -c 3000000 /dev/zero; echo done >&2; exit 3"], cwd: "/tmp", env: env, timeLimit: 30, limit: 1 << 20)
    #expect(r.status == 3 && !r.timedOut && r.truncated)
    #expect(r.stdout.count == 1 << 20 && String(decoding: r.stderr, as: UTF8.self) == "done\n")
    let whole = try Subprocess.run(["/bin/sh", "-c", "head -c 1048576 /dev/zero"], cwd: "/tmp", env: env, timeLimit: 30, limit: 1 << 20)
    #expect(whole.stdout.count == 1 << 20 && !whole.truncated)   // exactly the limit is all of it
}
