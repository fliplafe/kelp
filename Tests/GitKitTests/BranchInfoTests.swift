import Foundation
import Testing
@testable import GitKit

/// What Source Control shows about branches, read from one for-each-ref: checked against what git itself says.
@Test func branchInfoMatchesGitInEveryState() throws {
    let origin = try tempRepo()
    let repo = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-\(UUID().uuidString)").path
    try Git.run(["clone", "-q", origin, repo], cwd: FileManager.default.temporaryDirectory.path)
    defer { try? FileManager.default.removeItem(atPath: origin); try? FileManager.default.removeItem(atPath: repo) }
    try Git.run(["config", "user.email", "t@t"], cwd: repo); try Git.run(["config", "user.name", "t"], cwd: repo)
    func commit(_ dir: String, _ name: String) throws {
        try name.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        try Git.run(["add", name], cwd: dir); try Git.run(["commit", "-qm", name], cwd: dir)
    }
    func short(_ ref: String) throws -> String { try Git.run(["rev-parse", "--short", ref], cwd: repo).trimmingCharacters(in: .whitespacesAndNewlines) }

    // Even with origin, then 2 ahead and 1 behind.
    var b = try Git.branches(repo), head = try short("HEAD")
    #expect(b.current == "main" && b.upstream == "origin/main" && b.ahead == 0 && b.behind == 0 && b.head == head)
    #expect(b.remote == ["origin/main"] && b.local == ["main"] && !b.merging)   // origin/HEAD isn't a branch
    try commit(repo, "x"); try commit(repo, "y"); try commit(origin, "z")
    try Git.run(["fetch", "-q"], cwd: repo)
    b = try Git.branches(repo); head = try short("HEAD")
    #expect(b.ahead == 2 && b.behind == 1 && b.head == head)

    // A branch without an upstream, and one whose upstream was deleted.
    try Git.run(["switch", "-q", "-c", "feat/a"], cwd: repo)
    b = try Git.branches(repo)
    #expect(b.current == "feat/a" && b.upstream == nil && b.ahead == nil && b.local == ["feat/a", "main"])
    try Git.run(["push", "-q", "-u", "origin", "feat/a"], cwd: repo)
    #expect(try Git.branches(repo).upstream == "origin/feat/a")
    try Git.run(["branch", "-q", "-D", "feat/a"], cwd: origin); try Git.run(["fetch", "-q", "--prune"], cwd: repo)
    b = try Git.branches(repo)
    #expect(b.current == "feat/a" && b.upstream == nil && b.remote == ["origin/main"])

    // Detached: no current branch, HEAD still named.
    try Git.run(["switch", "-q", "--detach", "HEAD~1"], cwd: repo)
    b = try Git.branches(repo); head = try short("HEAD")
    #expect(b.current == nil && b.head == head && b.upstream == nil)

    // Before the first commit: the branch HEAD will be on, no hash.
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: empty) }
    try Git.run(["init", "-q", "-b", "trunk"], cwd: empty)
    b = try Git.branches(empty)
    #expect(b.current == "trunk" && b.head == nil && b.local.isEmpty)
}

@Test func oneFilesStatusLooksOnlyAtIt() throws {
    let repo = try tempRepo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    try "n\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    try "e\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    #expect(try Git.status(repo, only: "new.txt").map(\.path) == ["new.txt"])
    #expect(try Set(Git.status(repo).map(\.path)) == [".env", "new.txt", "f.txt"])
    #expect(try Git.diff(repo, source: .unstaged, file: "new.txt").map(\.path) == ["new.txt"])
}

@Test func aFileDeletedFromTheFolderLeavesTheList() throws {
    let repo = try tempRepo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    try FileManager.default.createDirectory(atPath: repo + "/d", withIntermediateDirectories: true)
    try "x\n".write(toFile: repo + "/d/kept.txt", atomically: true, encoding: .utf8)
    try "y\n".write(toFile: repo + "/gone.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], cwd: repo); try Git.run(["commit", "-qm", "files"], cwd: repo)
    try FileManager.default.removeItem(atPath: repo + "/gone.txt")
    try "n\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    #expect(try Set(ProjectFiles.list(repo)) == ["f.txt", ".env", "d/kept.txt", "new.txt"])
}
