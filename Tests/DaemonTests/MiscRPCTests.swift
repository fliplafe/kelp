import Foundation
import Testing
import Core
import GitKit
import Agents
@testable import Daemon

private struct World {
    let d: Daemon, c: RPCClient, root: URL, repo: Repo
}
private func world(agents: [AgentManifest] = []) async throws -> World {
    let root = tmp(); let d = try Daemon(root: root)
    if !agents.isEmpty {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agents"), withIntermediateDirectories: true)
        for a in agents { try JSONEncoder().encode(a).write(to: root.appendingPathComponent("agents/\(a.id).json")) }
    }
    try d.start()
    let c = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
    return World(d: d, c: c, root: root, repo: try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self))
}
private func desk(_ w: World, _ branch: String) async throws -> Worktree {
    try await w.c.call("worktree.create", .obj(["repoId": .string(w.repo.id), "branch": .string(branch), "setup": false]), as: Worktree.self)
}

@Test func anIdleSessionIsNotBusyAndDetachingNeverEndsIt() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "busy")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "command": "cat"]), as: Session.self)
    #expect(try await w.c.call("session.busy", .obj(["id": .string(s.id)])) == .null)   // its own program is in the foreground: nothing else running
    #expect(try await w.c.call("session.busy", .obj(["id": "gone"])) == .null)           // a session that isn't there isn't busy either
    _ = try await w.c.call("session.detach", .obj(["id": .string(s.id)]))
    #expect(try await w.c.call("session.list", as: [Session].self).contains { $0.id == s.id })
}

@Test func fetchAndPullTalkToTheRemoteAndTheWebLinkFollowsOrigin() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "feat/net")
    let bare = tmp().path
    try Git.run(["init", "-q", "--bare", "-b", "main"], cwd: bare)
    try Git.run(["remote", "add", "origin", bare], cwd: wt.path)
    try Git.run(["push", "-q", "-u", "origin", "feat/net"], cwd: wt.path)
    // Someone else pushes a commit to that branch; fetch sees it, pull brings it in.
    let other = tmp().path
    try Git.run(["clone", "-q", "-b", "feat/net", bare, other], cwd: tmp().path)
    try Git.run(["config", "user.email", "t@t"], cwd: other); try Git.run(["config", "user.name", "t"], cwd: other)
    try "theirs\n".write(toFile: other + "/theirs.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], cwd: other); try Git.run(["commit", "-qm", "theirs"], cwd: other); try Git.run(["push", "-q"], cwd: other)
    _ = try await w.c.call("git.remote", .obj(["id": .string(wt.id), "op": "fetch"]))
    #expect(!FileManager.default.fileExists(atPath: wt.path + "/theirs.txt"))   // fetched, not merged
    _ = try await w.c.call("git.remote", .obj(["id": .string(wt.id), "op": "pull"]))
    #expect(FileManager.default.fileExists(atPath: wt.path + "/theirs.txt"))
    await #expect(throws: (any Error).self) { _ = try await w.c.call("git.remote", .obj(["id": .string(wt.id), "op": "explode"])) }

    try Git.run(["remote", "set-url", "origin", "git@github.com:o/r.git"], cwd: wt.path)
    let url = try await w.c.call("git.webURL", .obj(["path": .string(wt.path + "/a.txt"), "start": 4, "end": 2])).string ?? ""
    #expect(url.hasPrefix("https://github.com/o/r/blob/") && url.hasSuffix("/a.txt#L2-L4"))   // the range is put in order
    try Git.run(["remote", "set-url", "origin", "/some/local/path"], cwd: wt.path)
    await #expect(throws: (any Error).self) { _ = try await w.c.call("git.webURL", .obj(["path": .string(wt.path + "/a.txt")])) }
}

@Test func cancellingAnUnknownCloneIsHarmless() async throws {
    let w = try await world(); defer { w.d.stop() }
    _ = try await w.c.call("repo.cloneCancel", .obj(["id": "never-started"]))
}

@Test func anIssueBecomesABranchADeskAndABriefedAgent() async throws {
    let script = #"read -r l; echo "BRIEF:$l""#
    let fake = AgentManifest(id: "fake", name: "Fake", command: "/bin/zsh", args: ["-c", script], autoAnswers: [], resumeArgs: [])
    let w = try await world(agents: [fake]); defer { w.d.stop() }
    let r = try await w.c.call("task.fromIssue", .obj(["repoId": .string(w.repo.id), "ref": "#42", "title": "Crash on launch", "body": "Steps to reproduce", "agent": "fake"]))
    let wt = try #require(r["worktree"]).decode(Worktree.self), s = try #require(r["session"]).decode(Session.self)
    #expect(wt.branch.contains("42") && wt.issue == "#42" && wt.note == "#42 Crash on launch")
    #expect(FileManager.default.fileExists(atPath: wt.path) && s.worktreeId == wt.id)
    // A second task for the same issue gets its own branch rather than failing on the name.
    let again = try await w.c.call("task.fromIssue", .obj(["repoId": .string(w.repo.id), "ref": "#42", "title": "Crash on launch", "agent": "fake"]))
    #expect(try #require(again["worktree"]).decode(Worktree.self).branch != wt.branch)
    let prefixed = try await w.c.call("task.fromIssue", .obj(["repoId": .string(w.repo.id), "ref": "#7", "title": "Add dark mode", "agent": "fake", "branchPrefix": "me/"]))
    #expect(try #require(prefixed["worktree"]).decode(Worktree.self).branch.hasPrefix("me/"))
}

@Test func agentVersionsListEachInstalledAgentWithItsVersion() async throws {
    let dir = tmp()
    let tool = dir.appendingPathComponent("demo-agent").path
    try "#!/bin/sh\necho 'demo-agent 4.5.6 (build 1)'\n".write(toFile: tool, atomically: true, encoding: .utf8)
    chmod(tool, 0o755)
    let gone = AgentManifest(id: "gone", name: "Gone", command: "/nonexistent/agent", args: [], autoAnswers: [], resumeArgs: [])
    let demo = AgentManifest(id: "demo", name: "Demo", command: tool, args: [], autoAnswers: [], resumeArgs: [])
    let w = try await world(agents: [demo, gone]); defer { w.d.stop() }
    let rows = try await w.c.call("agents.versions").array ?? []
    #expect(rows.first { $0["id"]?.string == "demo" }?["version"]?.string == "4.5.6")
    #expect(!rows.contains { $0["id"]?.string == "gone" })   // not installed: not listed
}

@Test func planLimitsAreReadInAFolderTheAgentAlreadyTrusts() {
    func pick(_ used: [String], _ trusted: [String], usable: Set<String>? = nil) -> String? {
        Daemon.probeFolder(used: used, trusted: trusted, remoteRoot: "/h/.kelp/remote") { usable?.contains($0) ?? true }
    }
    // The newest session was in a remote project's local folder: it holds nothing, and the agent never trusted it.
    #expect(pick(["/h/.kelp/remote/box/app", "/p/web"], ["/p/web", "/p/api"]) == "/p/web")
    // A recent folder the agent hasn't trusted would stop at its trust question: a trusted one is used instead.
    #expect(pick(["/tmp/scratch"], ["/p/web", "/p/api"]) == "/p/api")   // trusted ones in a stable order
    #expect(pick([], ["/p/web"]) == "/p/web")                             // no sessions yet: still something to read from
    #expect(pick(["/p/new"], []) == "/p/new")                             // no trust list to go by: recent folders as before
    #expect(pick(["/p/gone"], ["/p/gone", "/p/api"], usable: ["/p/api"]) == "/p/api")   // a folder that no longer exists is skipped
    #expect(pick([], []) == nil)
}
