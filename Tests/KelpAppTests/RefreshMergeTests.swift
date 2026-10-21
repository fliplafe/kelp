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

/// Workspaces follow `event.worktree` / `event.removed`: one renamed or removed while the list was on its way keeps what the
/// event said — a removed one doesn't come back from the older list.
@MainActor
@Test func aListOnItsWayDoesntBringBackARemovedWorkspace() {
    let kept = Worktree(repoId: "r", branch: "main", path: "/p", note: "Workspace 1")
    var renamed = kept; renamed.note = "Renamed"
    let removed = Worktree(repoId: "r", branch: "main", path: "/p", note: "Workspace 2")
    let merged = AppModel.merge(list: [kept, removed], local: [renamed], newer: [kept.id, removed.id])
    #expect(merged == [renamed])
}

/// Sessions follow `event.removed` (a typed event): one deleted for good leaves the list (its tab and row go), except one
/// a restart is replacing, whose tab the new session takes when the restart comes back.
@MainActor
@Test func aRemovedSessionLeavesTheListUnlessARestartReplacesIt() {
    let m = AppModel.shared
    let gone = Session(worktreeId: "w", cwd: "/tmp", command: "zsh", agent: "shell")
    let restarted = Session(worktreeId: "w", cwd: "/tmp", command: "claude", agent: "claude")
    m.upsert(gone); m.upsert(restarted)
    #expect(m.session(gone.id) != nil && m.session(restarted.id) != nil)
    m.restarting.insert(restarted.id)
    m.handle(RemovedEvent(session: gone.id)); m.handle(RemovedEvent(session: restarted.id))
    #expect(m.session(gone.id) == nil)
    #expect(m.session(restarted.id) != nil)
    m.restarting.remove(restarted.id); m.sessions.removeAll { $0.id == restarted.id }
}
