import Foundation
import Testing
import Core
@testable import Daemon

@Test func storeRoundTrip() throws {
    let s = try Store()
    let r = Repo(name: "demo", path: "/tmp/demo")
    try s.save(r)
    let w = Worktree(repoId: r.id, branch: "feat", path: "/tmp/w", note: "hi")
    try s.save(w)
    #expect(try s.repos() == [r])
    #expect(try s.worktree(w.id)?.note == "hi")
    try s.delete(r)
    #expect(try s.worktrees().isEmpty) // cascade
}

/// Two changes to one workspace at once (a rename and a PR link) both stay: neither saves back a copy read before the other.
@Test func workspaceChangesAtTheSameTimeAllStay() async throws {
    let s = try Store()
    let r = Repo(name: "demo", path: "/tmp/demo"); try s.save(r)
    let w = Worktree(repoId: r.id, branch: "b", path: "/p")
    try s.save(w)
    await withTaskGroup(of: Void.self) { g in
        for i in 0..<200 {
            g.addTask { _ = try? s.update(Worktree.self, w.id) { if i.isMultiple(of: 2) { $0.note += "n" } else { $0.prURL += "u" } } }
        }
    }
    let after = try #require(try s.worktree(w.id))
    #expect(after.note.count == 100 && after.prURL.count == 100)
}

/// A workspace's review comments go with it, also when its whole project is removed.
@Test func commentsGoWithTheirWorkspace() throws {
    let s = try Store()
    let r = Repo(name: "demo", path: "/tmp/demo"); try s.save(r)
    let w = Worktree(repoId: r.id, branch: "b", path: "/p"); try s.save(w)
    try s.save(DiffComment(worktreeId: w.id, file: "a", startLine: 1, endLine: 1, quote: "", text: "fix"))
    #expect(try s.comments(worktree: w.id).count == 1)
    try s.delete(r)   // cascades to the workspace
    #expect(try s.comments(worktree: w.id).isEmpty)
}
