import Foundation
import Testing
@testable import GitKit

func tempRepo() throws -> String {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-\(UUID().uuidString)").path
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
    #expect(try Git.run(["worktree", "list"], cwd: repo).contains("[feat/x]"))
    #expect(try Git.linkedWorktrees(repo).map { ($0.path as NSString).lastPathComponent } == ["feat-x"])   // the main checkout isn't one
    #expect(try Git.linkedWorktrees(repo).first?.branch == "feat/x")
    try Git.run(["worktree", "lock", p], cwd: repo)
    #expect(try Git.linkedWorktrees(repo).first?.locked == true)
    #expect(throws: GitError.self) { try Git.run(["worktree", "remove", p], cwd: repo) }   // what "Remove Clean Worktrees" relies on
    try Git.run(["worktree", "unlock", p], cwd: repo)
    #expect(try Git.linkedWorktrees(repo).first?.locked == false)
    try "dirty".write(toFile: p + "/n.txt", atomically: true, encoding: .utf8)
    #expect(throws: GitError.self) { try Git.removeWorktree(repo: repo, path: p, branch: "feat/x", force: false) }
    try Git.removeWorktree(repo: repo, path: p, branch: "feat/x", force: true)
    #expect(!(try Git.run(["worktree", "list"], cwd: repo).contains("[feat/x]")))
    #expect(try Git.linkedWorktrees(repo).isEmpty)
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
    let a = ProjectFiles.fuzzyScore("Sources/KelpApp/AppDelegate.swift", "appdel")!
    let b = ProjectFiles.fuzzyScore("Sources/a/p/p/d/e/l.swift", "appdel")!
    #expect(a > b)
    #expect(ProjectFiles.fuzzyScore("abc", "abd") == nil)
}

@Test func graphLanesFollowBranchesAndMerges() {
    // M merges P2 into P1; both come from B.
    let g = Git.lanes([("M", ["P1", "P2"]), ("P1", ["B"]), ("P2", ["B"]), ("B", [])])
    #expect(g.map(\.lane) == [0, 0, 1, 0])
    #expect(g[0].top.isEmpty && g[0].bottom == [[0, 0], [0, 1]])
    #expect(g[1].top == [[0, 0], [1, 1]] && g[1].bottom == [[1, 1], [0, 0]])
    #expect(g[2].top == [[0, 0], [1, 1]] && g[2].bottom == [[0, 0], [1, 0]])   // P2 joins B's lane
    #expect(g[3].top == [[0, 0]] && g[3].bottom.isEmpty)
    // The trunk keeps lane 0 when a side branch already waits for the same parent further right.
    let t = Git.lanes([("M", ["L", "D"]), ("D", ["X"]), ("L", ["X"]), ("X", [])])
    #expect(t.map(\.lane) == [0, 1, 0, 0])
    #expect(t[2].bottom == [[1, 1], [0, 0]] && t[3].top == [[0, 0], [1, 0]])
}

@Test func unpushedIsWhatNoRemoteBranchReaches() {
    func c(_ h: String, _ p: [String], _ refs: [String] = []) -> GraphCommit {
        GraphCommit(hash: h, parents: p, author: "", date: 0, subject: "", refs: refs, lane: 0, top: [], bottom: [])
    }
    // main is two ahead of origin/main; "side" was never published and forks from a pushed commit.
    let list = [c("L2", ["L1"], ["HEAD -> main"]), c("S", ["B"], ["side"]), c("L1", ["R"]),
                c("R", ["B"], ["origin/main", "origin/HEAD"]), c("B", [])]
    #expect(Git.unpushed(list, remotes: ["origin/main"]) == ["L2", "L1", "S"])
    #expect(Git.unpushed(list, remotes: []).isEmpty)   // no remote at all: nothing to mark
}

@Test func graphAndBranchesFromARealRepo() throws {
    let repo = try tempRepo()
    try Git.run(["switch", "-q", "-c", "feature"], cwd: repo)
    try "g\n".write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "g.txt"], cwd: repo); try Git.run(["commit", "-qm", "feature work"], cwd: repo)
    try Git.run(["switch", "-q", "main"], cwd: repo)
    try Git.run(["merge", "-q", "--no-ff", "-m", "merge feature", "feature"], cwd: repo)
    let (commits, more) = try Git.graph(repo, limit: 50)
    #expect(!more && commits.first?.subject == "merge feature" && commits.first?.parents.count == 2)
    #expect(commits.first?.refs.contains { $0.hasPrefix("HEAD -> ") } == true)
    #expect(try Git.commitFiles(repo, commit: commits[0].hash).map(\.path) == ["g.txt"])
    let b = try Git.branches(repo)
    #expect(b.current == "main" && b.local.contains("feature") && !b.merging)
    // Pop keeps what was staged staged.
    try "x\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    try Git.stage(repo, files: ["f.txt"]); try Git.stash(repo, pop: false); try Git.stash(repo, pop: true)
    #expect(try Git.status(repo).first { $0.path == "f.txt" }?.staged == true)
}

@Test func gitErrorsReadAsOneSentence() {
    let e = GitError(args: ["push"], status: 128, stderr: "fatal: 'origin' does not appear to be a git repository\nfatal: Could not read from remote repository.")
    #expect(e.message == "'origin' does not appear to be a git repository")
    let c = GitError(args: ["switch"], status: 1, stderr: "error: Your local changes to the following files would be overwritten by checkout:\n\tf.txt\nAborting")
    #expect(c.message == "Your local changes to the following files would be overwritten by checkout: f.txt")
}

@Test func webLinks() {
    #expect(Git.webRepo("git@github.com:o/r.git")! == ("github.com", "o/r"))
    #expect(Git.webRepo("ssh://git@gitlab.example.com:2222/team/sub/r.git")! == ("gitlab.example.com", "team/sub/r"))
    #expect(Git.webRepo("https://me@bitbucket.org/ws/r.git")! == ("bitbucket.org", "ws/r"))
    #expect(Git.webRepo("/local/path") == nil)
    #expect(Git.webURL(remote: "git@github.com:o/r.git", sha: "abc", file: "a b/c.swift", lines: 3...5) == "https://github.com/o/r/blob/abc/a%20b/c.swift#L3-L5")
    #expect(Git.webURL(remote: "https://gitlab.com/o/r", sha: "abc", file: "c.swift", lines: 7...7) == "https://gitlab.com/o/r/-/blob/abc/c.swift#L7")
    #expect(Git.webURL(remote: "git@bitbucket.org:o/r.git", sha: "abc", file: "c.swift", lines: 1...2) == "https://bitbucket.org/o/r/src/abc/c.swift#lines-1:2")
}

@Test func lineKinds() {
    #expect(LineStats.kind("Sources/App.swift") == .code)
    #expect(LineStats.kind("Tests/AppTests/AppTests.swift") == .tests)
    #expect(LineStats.kind("src/__tests__/a.ts") == .tests)
    #expect(LineStats.kind("web/button.test.tsx") == .tests)
    #expect(LineStats.kind("package-lock.json") == .generated)
    #expect(LineStats.kind("ui/vendor.min.js") == .generated)
    #expect(LineStats.kind("contest/main.go") == .code)
}

@Test func snapshotSeesNewAndChangedFiles() throws {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString.prefix(6))").path
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    try Git.run(["init", "-q", "-b", "main"], cwd: d)
    try Git.run(["config", "user.email", "t@t"], cwd: d); try Git.run(["config", "user.name", "t"], cwd: d)
    try "a\n".write(toFile: d + "/a.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], cwd: d); try Git.run(["commit", "-qm", "init"], cwd: d)
    try "a\nb\n".write(toFile: d + "/a.txt", atomically: true, encoding: .utf8)   // changed before the turn: not the agent's
    let base = try Git.snapshotTree(d)
    try "a\nb\nc\n".write(toFile: d + "/a.txt", atomically: true, encoding: .utf8)
    try "new\n".write(toFile: d + "/n.txt", atomically: true, encoding: .utf8)
    let ch = try Git.changesSince(tree: base, cwd: d)
    #expect(ch.map(\.path).sorted() == ["a.txt", "n.txt"])
    #expect(ch.first { $0.path == "a.txt" }?.added == 1)
    #expect(try Git.status(d).contains { $0.untracked && $0.path == "n.txt" })   // the real index is untouched
    #expect(try Git.diff(d, source: .since(tree: base)).count == 2)
}
