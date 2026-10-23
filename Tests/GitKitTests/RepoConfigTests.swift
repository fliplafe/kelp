import Foundation
import Testing
import TestSupport
@testable import GitKit
import Core

/// A folder that came with its own .git/config (a download, not a clone): what Kelp runs by itself must not start its programs.
@Test func aReposOwnConfigRunsNoProgramOnStatusOrDiff() throws {
    let repo = try tempRepo()
    let ran = repo + "/ran", script = repo + "/x.sh"
    try "#!/bin/sh\ntouch '\(ran)'\ncat \"$1\" 2>/dev/null\n".write(toFile: script, atomically: true, encoding: .utf8)
    chmod(script, 0o755)
    try Git.run(["config", "core.fsmonitor", script], cwd: repo)
    try Git.run(["config", "diff.x.textconv", script], cwd: repo)
    try Git.run(["config", "filter.x.clean", script + " %f"], cwd: repo)
    try "*.txt diff=x filter=x\n".write(toFile: repo + "/.git/info/attributes", atomically: true, encoding: .utf8)
    try "a\nB\nc\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)   // the same size: status has to read it
    #expect(try Git.status(repo).contains { $0.path == "f.txt" })
    #expect(try Git.diff(repo, source: .unstaged).first?.hunks.isEmpty == false)
    #expect(!FileManager.default.fileExists(atPath: ran))
    // From a linked worktree too, whose config is the main repository's.
    let wt = try Git.addWorktree(repo: repo, branch: "w", base: "main", into: URL(fileURLWithPath: repo + "-wt"), copyFiles: [])
    try "a\nB\nc\n".write(toFile: wt + "/f.txt", atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(atPath: ran)
    #expect(try Git.status(wt).contains { $0.path == "f.txt" })
    #expect(!FileManager.default.fileExists(atPath: ran))
    try Git.run(["add", "f.txt"], cwd: repo)   // what the user does keeps the repo's filter
    #expect(FileManager.default.fileExists(atPath: ran))
    try Git.run(["-c", "filter.x.clean=", "commit", "-qm", "two"], cwd: repo)
    try FileManager.default.removeItem(atPath: ran)
    _ = try Git.run(["show", "HEAD"], cwd: repo)   // any patch Kelp reads, not only Diff's
    _ = try Git.run(["log", "-p", "-1"], cwd: repo)
    #expect(!FileManager.default.fileExists(atPath: ran))
}

/// A branch that commits a folder as a symlink out of the project can't have the user's ignored files copied there:
/// `.worktreeinclude` (a file the repository ships) names them, the copy stays inside the new worktree or doesn't happen.
@Test func copiedFilesStayInTheWorktree() throws {
    let repo = try tempRepo(), outside = tmp().path
    try FileManager.default.createDirectory(atPath: repo + "/conf", withIntermediateDirectories: true)
    try "TOKEN=1\n".write(toFile: repo + "/conf/.env", atomically: true, encoding: .utf8)
    try "conf/.env\n.env\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
    try ".env\n".write(toFile: repo + "/.worktreeinclude", atomically: true, encoding: .utf8)
    try Git.run(["add", ".gitignore", ".worktreeinclude"], cwd: repo); try Git.run(["commit", "-qm", "include"], cwd: repo)
    try Git.run(["checkout", "-qb", "evil"], cwd: repo)
    try FileManager.default.moveItem(atPath: repo + "/conf", toPath: repo + "/conf-real")
    try FileManager.default.createSymbolicLink(atPath: repo + "/conf", withDestinationPath: outside)
    try Git.run(["add", "conf"], cwd: repo); try Git.run(["commit", "-qm", "link"], cwd: repo)
    try Git.run(["checkout", "-q", "main"], cwd: repo)   // takes the link away
    try FileManager.default.moveItem(atPath: repo + "/conf-real", toPath: repo + "/conf")
    let p = try Git.addWorktree(repo: repo, branch: "w", base: "evil", into: URL(fileURLWithPath: repo + "-wt"), copyFiles: ["conf/.env"])
    #expect(!FileManager.default.fileExists(atPath: outside + "/.env"))
    #expect(FileManager.default.fileExists(atPath: p + "/.env"))   // one inside still comes
}
