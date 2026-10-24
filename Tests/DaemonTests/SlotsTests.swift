import Foundation
import os
import Testing
@testable import Daemon

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
