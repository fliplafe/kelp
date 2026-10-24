import Foundation
import os
import Testing
@testable import Daemon
import Core

/// Quick work has a cap of its own: past it, more waits for a turn instead of each starting a thread.
@Test func quickWorkWaitsPastItsOwnCap() async throws {
    let slots = Slots(8, quick: 2)
    let running = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
    try await withThrowingTaskGroup(of: Void.self) { g in
        for _ in 0..<6 {
            g.addTask {
                try await slots.run(quick: true) {
                    running.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
                    usleep(100_000)
                    running.withLock { $0.now -= 1 }
                }
            }
        }
        try await g.waitForAll()
    }
    #expect(running.withLock { $0.most } == 2)
}

/// What the user is waiting on (a paused tab waking) runs at once, not after every held slot.
@Test func workRunNowDoesntWaitForASlot() async throws {
    let slots = Slots(1), held = DispatchSemaphore(value: 0)
    let slow = Task { try await slots.run { held.wait() } }
    try await Task.sleep(for: .milliseconds(100))   // the one slot is taken
    #expect(try await slots.runNow { 42 } == 42)
    held.signal()
    try await slow.value
}

/// A client that sends without ever ending its line is hung up on past the line limit, not kept in memory for good.
@Test func aLineThatNeverEndsIsHungUpOn() async throws {
    let (d, _, root) = try daemon(); defer { d.stop() }
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
    defer { close(fd) }
    Unix.noSigPipe(fd)
    let chunk = Data(repeating: 0x61, count: 1 << 20)
    var sent = 0
    while sent <= Daemon.lineLimit + (8 << 20), Unix.writeAll(fd, chunk) { sent += chunk.count }
    #expect(sent <= Daemon.lineLimit + (8 << 20))   // a write failed: the daemon hung up
}
