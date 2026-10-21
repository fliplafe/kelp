import Foundation
import Testing
import Core
@testable import KelpApp

/// A session list that was on its way while an event about a session came doesn't take that session back: the event
/// (sent after the list was read, or as it was) wins; the others come from the list.
@MainActor
@Test func aListOnItsWayDoesntUndoANewerEvent() {
    var done = Session(worktreeId: "w", cwd: "/tmp", command: "claude", agent: "claude"); done.status = .done
    var stale = done; stale.status = .working
    let other = Session(worktreeId: "w", cwd: "/tmp", command: "zsh", agent: "shell")
    let created = Session(worktreeId: "w", cwd: "/tmp", command: "codex", agent: "codex")   // created after the list was read
    let merged = AppModel.merge(list: [stale, other], local: [done, created], newer: [done.id, created.id])
    #expect(merged.map(\.id) == [done.id, other.id, created.id])
    #expect(merged.first?.status == .done)
    #expect(AppModel.merge(list: [stale, other], local: [done], newer: []) == [stale, other])   // nothing newer: the list
}
