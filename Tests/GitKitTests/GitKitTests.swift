import Foundation
import Testing
@testable import GitKit

func tempRepo() throws -> String {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("krill-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    try Git.run(["init", "-q", "-b", "main"], cwd: d)
    try Git.run(["config", "user.email", "t@t"], cwd: d); try Git.run(["config", "user.name", "t"], cwd: d)
    try "a\nb\nc\n".write(toFile: d + "/f.txt", atomically: true, encoding: .utf8)
    try "SECRET=1\n".write(toFile: d + "/.env", atomically: true, encoding: .utf8)
    try Git.run(["add", "f.txt"], cwd: d); try Git.run(["commit", "-qm", "init"], cwd: d)
    return d
}

@Test func worktreeLifecycle() throws {
    let repo = try tempRepo()
    let dir = URL(fileURLWithPath: repo + "-wt")
    let p = try Git.addWorktree(repo: repo, branch: "feat/x", base: "main", into: dir, copyFiles: [".env"])
    #expect(FileManager.default.fileExists(atPath: p + "/.env"))
    #expect(try Git.listWorktrees(repo: repo).contains { $0.branch == "feat/x" })
    try "dirty".write(toFile: p + "/n.txt", atomically: true, encoding: .utf8)
    #expect(throws: GitError.self) { try Git.removeWorktree(repo: repo, path: p, branch: "feat/x", force: false) }
    try Git.removeWorktree(repo: repo, path: p, branch: "feat/x", force: true)
    #expect(try Git.listWorktrees(repo: repo).count == 1)
}

@Test func diffParseAndHunkStaging() throws {
    let repo = try tempRepo()
    let big = (1...30).map(String.init).joined(separator: "\n") + "\n"
    try big.write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "g.txt"], cwd: repo); try Git.run(["commit", "-qm", "g"], cwd: repo)
    var lines = big.split(separator: "\n").map(String.init)
    lines[1] = "two"; lines[28] = "twenty-nine"
    try (lines.joined(separator: "\n") + "\n").write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)

    let d = try Git.diff(repo, source: .unstaged, file: "g.txt")
    #expect(d.count == 1 && d[0].hunks.count == 2)
    #expect(d[0].additions == 2 && d[0].deletions == 2)
    #expect(d[0].hunks[0].lines.first { $0.kind == .add }?.newLine == 2)

    try Git.applyHunk(repo, diff: d[0], hunk: 1, reverse: false)
    let staged = try Git.diff(repo, source: .staged)
    #expect(staged[0].hunks.count == 1 && staged[0].hunks[0].lines.contains { $0.text == "twenty-nine" })
    let rest = try Git.diff(repo, source: .unstaged, file: "g.txt")
    #expect(rest[0].hunks.count == 1 && rest[0].hunks[0].lines.contains { $0.text == "two" })
}

@Test func statusUntrackedAndCommit() throws {
    let repo = try tempRepo()
    try "x\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    let s = try Git.status(repo)
    #expect(s.contains { $0.path == "new.txt" && $0.untracked })
    let d = try Git.diff(repo, source: .allUncommitted)
    #expect(d.contains { $0.path == "new.txt" && $0.additions == 1 })
    try Git.stage(repo, files: ["new.txt"])
    _ = try Git.commit(repo, message: "add new")
    #expect(try Git.log(repo, limit: 1).first?.subject == "add new")
}

@Test func mergeAndConflict() throws {
    let repo = try tempRepo()
    let dir = URL(fileURLWithPath: repo + "-wt")
    let p = try Git.addWorktree(repo: repo, branch: "feat", base: "main", into: dir, copyFiles: [])
    try "feat\n".write(toFile: p + "/f.txt", atomically: true, encoding: .utf8)
    try Git.commit(p, message: "feat", all: true)
    try "main\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Git.commit(repo, message: "main", all: true)
    let r = try Git.merge(branch: "feat", into: repo)
    #expect(!r.merged && r.conflicts == ["f.txt"])
    #expect(try Git.status(repo).filter(\.conflicted).isEmpty) // aborted cleanly
}

@Test func branchDiff() throws {
    let repo = try tempRepo()
    let p = try Git.addWorktree(repo: repo, branch: "b", base: "main", into: URL(fileURLWithPath: repo + "-wt"), copyFiles: [])
    try "z\n".write(toFile: p + "/z.txt", atomically: true, encoding: .utf8)
    try Git.stage(p, files: ["z.txt"]); try Git.commit(p, message: "z")
    #expect(try Git.diff(p, source: .branch(base: "main")).map(\.path) == ["z.txt"])
    let c = try Git.log(p, base: "main")[0].hash
    #expect(try Git.diff(p, source: .commit(c)).map(\.path) == ["z.txt"])
}

@Test func sideBySidePairingAndGaps() {
    func l(_ k: DiffLine.Kind, _ t: String, o: Int? = nil, n: Int? = nil) -> DiffLine { DiffLine(kind: k, text: t, oldLine: o, newLine: n) }
    let h1 = Hunk(header: "@@ -1,3 +1,3 @@", oldStart: 1, newStart: 1, lines: [l(.context, "a", o: 1, n: 1), l(.del, "b", o: 2), l(.del, "c", o: 3), l(.add, "B", n: 2)])
    let p = DiffRows.pairs(h1.lines)
    #expect(p.count == 3)
    #expect(p[1].0?.text == "b" && p[1].1?.text == "B")
    #expect(p[2].0?.text == "c" && p[2].1 == nil)
    let h2 = Hunk(header: "@@ -20 +20 @@", oldStart: 20, newStart: 20, lines: [l(.add, "z", n: 20)])
    let rows = DiffRows.build([FileDiff(path: "f", header: "", hunks: [h1, h2], binary: false)], sideBySide: false)
    #expect(rows.contains(.gap(lines: 17)))
}

@Test func projectFilesAndSearch() throws {
    let repo = try tempRepo()
    try "ignored.txt\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
    try "needle here\n".write(toFile: repo + "/ignored.txt", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: repo + "/src", withIntermediateDirectories: true)
    try "let x = 1\nfind the needle\n".write(toFile: repo + "/src/main.swift", atomically: true, encoding: .utf8)
    let files = try ProjectFiles.list(repo)
    #expect(files.contains("src/main.swift") && !files.contains("ignored.txt"))
    let m = try ProjectFiles.search(repo, query: "needle")
    #expect(m == [SearchMatch(path: "src/main.swift", line: 2, text: "find the needle")])
}

@Test func fuzzyPrefersFileNames() {
    let a = ProjectFiles.fuzzyScore("Sources/KrillApp/AppDelegate.swift", "appdel")!
    let b = ProjectFiles.fuzzyScore("Sources/a/p/p/d/e/l.swift", "appdel")!
    #expect(a > b)
    #expect(ProjectFiles.fuzzyScore("abc", "abd") == nil)
}
