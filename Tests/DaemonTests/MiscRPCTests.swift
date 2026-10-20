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

@Test func aFailedCloneRemovesOnlyItsOwnFolder() async throws {
    let w = try await world(); defer { w.d.stop() }
    let parent = tmp().path
    // Someone else's folder already has the name this clone would use.
    try FileManager.default.createDirectory(atPath: parent + "/app", withIntermediateDirectories: true)
    try "mine\n".write(toFile: parent + "/app/keep.txt", atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { _ = try await w.c.call("repo.clone", .obj(["url": "/nonexistent/app.git", "parent": .string(parent), "id": "c1"])) }
    #expect(FileManager.default.fileExists(atPath: parent + "/app/keep.txt"))   // untouched
    // A clone that fails in a folder of its own leaves nothing behind.
    await #expect(throws: (any Error).self) { _ = try await w.c.call("repo.clone", .obj(["url": "/nonexistent/other.git", "parent": .string(parent), "id": "c2"])) }
    #expect(!FileManager.default.fileExists(atPath: parent + "/other"))
}

@Test func onlyOneCloneCanClaimAFolderName() throws {
    let parent = tmp().path
    #expect(Daemon.claim(parent + "/app"))      // the first clone gets the folder
    #expect(!Daemon.claim(parent + "/app"))     // a second one with the same name is refused before it can touch it
    try "theirs".write(toFile: parent + "/file", atomically: true, encoding: .utf8)
    #expect(!Daemon.claim(parent + "/file"))    // a file in the way counts too
}

/// `ssh` that runs the command here (the host is this Mac), shared with remoteProjectOverSSH: RemoteHost reads it once.
private let localSSH: String = {
    if let have = ProcessInfo.processInfo.environment["KELP_SSH"] { return have }
    let shim = tmp().appendingPathComponent("ssh")
    try? """
    #!/bin/sh
    while [ $# -gt 1 ]; do case "$1" in -o) shift 2;; -T|-tt|--) shift;; *) shift; break;; esac; done
    exec /bin/sh -c "$1"
    """.write(to: shim, atomically: true, encoding: .utf8)
    chmod(shim.path, 0o755)
    setenv("KELP_SSH", shim.path, 1)
    return shim.path
}()

@Test func twoRemoteFoldersWithTheSameNameAreTwoProjects() async throws {
    _ = localSSH
    try #require(RemoteHost.ssh == localSSH)
    let w = try await world(); defer { w.d.stop() }
    let a = tmp().path + "/app", b = tmp().path + "/app"
    for p in [a, b] { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true); try Git.run(["init", "-q"], cwd: p) }
    let ra = try await w.c.call("repo.addRemote", .obj(["host": "box", "path": .string(a)]), as: Repo.self)
    let rb = try await w.c.call("repo.addRemote", .obj(["host": "box", "path": .string(b)]), as: Repo.self)
    #expect(ra.id != rb.id && ra.path != rb.path)                             // not the first project again
    #expect(RemoteHost.of(rb.path)?.path.hasSuffix(String(b.dropFirst(4))) == true)   // its agents run in its own folder
    let again = try await w.c.call("repo.addRemote", .obj(["host": "box", "path": .string(a)]), as: Repo.self)
    #expect(again.id == ra.id)                                                // adding the same one twice is still one project
}

@Test func aFailedRemoteAddRemovesOnlyItsOwnFolder() async throws {
    _ = localSSH
    try #require(RemoteHost.ssh == localSSH)
    let w = try await world(); defer { w.d.stop() }
    let good = tmp().path + "/svc"
    try FileManager.default.createDirectory(atPath: good, withIntermediateDirectories: true); try Git.run(["init", "-q"], cwd: good)
    let kept = try await w.c.call("repo.addRemote", .obj(["host": "box", "path": .string(good)]), as: Repo.self)
    // "/x/.." used to name the remote folder itself; a failure then deleted every remote project's folder.
    await #expect(throws: (any Error).self) { _ = try await w.c.call("repo.addRemote", .obj(["host": "box", "path": "/nonexistent/.."])) }
    await #expect(throws: (any Error).self) { _ = try await w.c.call("repo.addRemote", .obj(["host": "box", "path": "/nonexistent/svc"])) }
    #expect(FileManager.default.fileExists(atPath: kept.path + "/" + RemoteHost.marker))   // the project that worked is untouched
    #expect(Daemon.remoteFolderName("/x/..") == "project" && Daemon.remoteFolderName("/") == "project" && Daemon.remoteFolderName("~") == "project")
    #expect(Daemon.remoteFolderName("/srv/app/") == "app")
}

@Test func deletingAWorkspaceNeverDropsCommitsWithoutBeingTold() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "feat/work")
    try "new\n".write(toFile: wt.path + "/n.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "n.txt"], cwd: wt.path); try Git.run(["commit", "-qm", "only here"], cwd: wt.path)
    #expect(try await w.c.call("worktree.unmerged", .obj(["id": .string(wt.id)])).int == 1)
    await #expect(throws: (any Error).self) { _ = try await w.c.call("worktree.remove", .obj(["id": .string(wt.id)])) }
    #expect(FileManager.default.fileExists(atPath: wt.path + "/n.txt") && Git.branchExists(w.repo.path, "feat/work"))   // nothing was removed
    _ = try await w.c.call("worktree.remove", .obj(["id": .string(wt.id), "dropCommits": true]))                        // the user said so
    #expect(!FileManager.default.fileExists(atPath: wt.path) && !Git.branchExists(w.repo.path, "feat/work"))
}

@Test func aBranchWhoseCommitsArePushedIsSafeToDelete() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "feat/pushed")
    try "x\n".write(toFile: wt.path + "/x.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "x.txt"], cwd: wt.path); try Git.run(["commit", "-qm", "x"], cwd: wt.path)
    let bare = tmp().path
    try Git.run(["init", "-q", "--bare", bare], cwd: bare)
    try Git.run(["remote", "add", "origin", bare], cwd: wt.path); try Git.run(["push", "-q", "-u", "origin", "feat/pushed"], cwd: wt.path)
    #expect(try await w.c.call("worktree.unmerged", .obj(["id": .string(wt.id)])).int == 0)   // on the remote: nothing would be lost
    _ = try await w.c.call("worktree.remove", .obj(["id": .string(wt.id)]))
    #expect(!Git.branchExists(w.repo.path, "feat/pushed"))
}

/// The ordering itself (applied on the reading thread, not one Task each) couldn't be made to fail here: requests start
/// in order on this Mac. What this checks is that state and sizes sent as notifications are applied, ending at the last.
@Test func stateSentAsNotificationsEndsAtTheLastValue() async throws {
    let w = try await world(); defer { w.d.stop() }
    for i in 1...300 { w.c.notify(StateSet(key: "layout.test", value: .int(i))) }   // as the app saves a layout while you drag
    #expect(try await waitFor(10) { try await w.c.call(StateGet(key: "layout.test")) == .int(300) })
    try await Task.sleep(for: .milliseconds(200))
    #expect(try await w.c.call(StateGet(key: "layout.test")) == .int(300))   // and nothing older lands after it
}

@Test func aSizeSentAsANotificationReachesTheTerminal() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "size")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "command": "cat"]), as: Session.self)
    for cols in stride(from: 40, through: 200, by: 2) { w.c.notify("session.resize", .obj(["id": .string(s.id), "cols": .int(cols), "rows": 30])) }
    _ = try await w.c.call("ping")   // the notifications before it have been read
    let live = try #require(w.d.existing(s.id))
    #expect(try await waitFor(5) { live.pty.size?.cols == 200 })
}

@Test func aShortTurnIsNotCreditedWithThePreviousTurnsChanges() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "turns")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "command": "cat", "agent": "claude-like"]), as: Session.self)
    let live = try #require(w.d.existing(s.id))
    live.noteTurn(.working)                                              // turn 1: changes a file
    #expect(try await waitFor(5) { live.turnBase != nil })
    try "changed\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    live.noteTurn(.idle)
    #expect(try await waitFor(5) { live.lastTurn?.files.map(\.path) == ["a.txt"] })
    live.noteTurn(.working); live.noteTurn(.idle)                        // turn 2: over at once, changed nothing
    #expect(try await waitFor(5) { live.lastTurn?.files.isEmpty == true }, "turn 2 reported \(live.lastTurn?.files.map(\.path) ?? [])")
}

/// Kelp answers an agent's "trust this folder?" only for a project the agent already trusts.
@Test func theTrustQuestionIsAnsweredOnlyForAFolderTheAgentTrusts() async throws {
    let script = #"stty -icanon -echo; printf 'Do you trust the files in this folder?\n\xe2\x9d\xaf 1. Yes, proceed\n  2. No, exit\n'; IFS= read -rsn1 -t 4 k && [[ -z "$k" ]] && echo TRUSTED-BY-KELP; sleep 30"#
    let config = tmp().path
    var fake = AgentManifest(id: "claude", name: "Claude Code", command: "/bin/bash", args: ["-c", script], autoAnswers: [AgentManifest.trust], resumeArgs: [])
    fake.env = ["CLAUDE_CONFIG_DIR": config]   // its own config, not the user's
    let w = try await world(agents: [fake]); defer { w.d.stop() }
    func run(_ wt: Worktree) async throws -> String {
        let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude"]), as: Session.self)
        _ = try await waitFor(8) { (try await w.c.call("session.read", .obj(["id": .string(s.id)]))).string?.contains("TRUSTED-BY-KELP") == true }
        return try await w.c.call("session.read", .obj(["id": .string(s.id)])).string ?? ""
    }
    let unknown = try await desk(w, "never-seen")
    #expect(try await run(unknown).contains("TRUSTED-BY-KELP") == false)   // a project it never trusted: the user is asked
    try #"{"projects":{"\#(w.repo.path)":{"hasTrustDialogAccepted":true}}}"#.write(toFile: config + "/.claude.json", atomically: true, encoding: .utf8)
    let known = try await desk(w, "new-desk")
    #expect(try await run(known).contains("TRUSTED-BY-KELP"))              // a new workspace of a project it trusts: answered
}
