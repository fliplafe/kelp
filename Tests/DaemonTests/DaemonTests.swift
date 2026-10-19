import Foundation
import Testing
import Core
import GitKit
@testable import Daemon
import Agents

func tmp() -> URL {
    // short path: unix socket paths are limited to ~104 bytes
    let u = URL(fileURLWithPath: "/tmp/kr-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func makeRepo() throws -> String {
    let d = tmp().path
    try Git.run(["init", "-q", "-b", "main"], cwd: d)
    try Git.run(["config", "user.email", "t@t"], cwd: d); try Git.run(["config", "user.name", "t"], cwd: d)
    try "hello\n".write(toFile: d + "/a.txt", atomically: true, encoding: .utf8)
    try "setup: touch SETUP_RAN\ntest: test -f SETUP_RAN\n".write(toFile: d + "/.krill.yaml", atomically: true, encoding: .utf8)
    try "SETUP_RAN\n".write(toFile: d + "/.gitignore", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], cwd: d); try Git.run(["commit", "-qm", "init"], cwd: d)
    return d
}

func waitFor(_ timeout: Double = 8, _ cond: () async throws -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if try await cond() { return true }; try await Task.sleep(for: .milliseconds(100)) }
    return false
}

@Test func endToEnd() async throws {
    let root = tmp()
    let d = try Daemon(root: root)
    try d.start(); defer { d.stop() }
    let c = try RPCClient(socket: root.appendingPathComponent("krill.sock").path)
    #expect(try await c.call("ping").string == "pong")

    let repoPath = try makeRepo()
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(repoPath)]), as: Repo.self)
    let wt: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "feat/one"]), as: Worktree.self)
    #expect(FileManager.default.fileExists(atPath: wt.path))
    // .krill.yaml setup script ran in the new worktree
    #expect(try await waitFor { FileManager.default.fileExists(atPath: wt.path + "/SETUP_RAN") })
    let t = try await c.call("worktree.test", .obj(["id": .string(wt.id)]))
    #expect(t["passed"]?.bool == true)

    // session: output, history on re-attach, hook status, send
    let notes = NoteBox(); c.onNotification = { m, p in notes.add(m, p) }
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(wt.id), "command": "echo ready; cat"]), as: Session.self)
    _ = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    #expect(try await waitFor { notes.output(s.id).contains("ready") })
    _ = try await c.call("session.send", .obj(["id": .string(s.id), "text": "ping-pong"]))
    #expect(try await waitFor { notes.output(s.id).contains("ping-pong") })

    let c2 = try RPCClient(socket: root.appendingPathComponent("krill.sock").path)   // a "restarted UI"
    let h = try await c2.call("session.attach", .obj(["id": .string(s.id)]))
    let hist = String(decoding: Data(base64Encoded: h["history"]!.string!)!, as: UTF8.self)
    #expect(hist.contains("ready") && hist.contains("ping-pong"))
    #expect(try await c2.call("session.read", .obj(["id": .string(s.id)])).string?.contains("ready") == true)

    _ = try await c2.call("session.hook", .obj(["id": .string(s.id), "event": "waiting"]))
    let list: [Session] = try await c2.call("session.list", as: [Session].self)
    #expect(list.first { $0.id == s.id }?.status == .waiting)
    #expect(list.first { $0.id == s.id }?.unread == true)

    // git flow through RPC: change, hunk list, stage, commit, merge
    try "hello\nworld\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    let diff: [FileDiff] = try await c2.call("git.diff", .obj(["id": .string(wt.id), "source": "unstaged"]), as: [FileDiff].self)
    #expect(diff.first?.path == "a.txt")
    _ = try await c2.call("git.stage", .obj(["id": .string(wt.id), "files": .array(["a.txt"])]))
    _ = try await c2.call("git.commit", .obj(["id": .string(wt.id), "message": "world"]))
    let m = try await c2.call("git.merge", .obj(["id": .string(wt.id)]))
    #expect(m["merged"]?.bool == true)
    #expect(try String(contentsOfFile: repoPath + "/a.txt", encoding: .utf8) == "hello\nworld\n")

    _ = try await c2.call("session.kill", .obj(["id": .string(s.id)]))
    #expect(try await waitFor { try await c2.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .exited })
}

@Test func reviewCommentsReachAgent() async throws {
    let root = tmp(); let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let c = try RPCClient(socket: root.appendingPathComponent("krill.sock").path)
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self)
    let wt: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "r", "setup": false]), as: Worktree.self)
    let box = NoteBox(); c.onNotification = { m, p in box.add(m, p) }
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(wt.id), "command": "cat"]), as: Session.self)
    _ = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    _ = try await c.call("comment.add", .obj(["id": .string(wt.id), "file": "a.txt", "start": 1, "end": 2, "quote": "hello", "text": "rename this"]))
    let n = try await c.call("comment.send", .obj(["id": .string(wt.id), "session": .string(s.id)]))
    #expect(n.int == 1)
    #expect(try await waitFor { box.output(s.id).contains("rename this") })
    let comments: [DiffComment] = try await c.call("comment.list", .obj(["id": .string(wt.id)]), as: [DiffComment].self)
    #expect(comments.first?.state == .sent)
}

@Test func fanoutCompareAccept() async throws {
    let root = tmp(); let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let c = try RPCClient(socket: root.appendingPathComponent("krill.sock").path)
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self)
    // fake agents: custom commands can't be passed as agent ids, so create worktrees via fan-out with the shell agent
    let r = try await c.call("fanout.start", .obj(["repoId": .string(repo.id), "prompt": "true", "agents": .array(["shell", "shell"]), "delay": 1]))
    #expect(r.array?.count == 2)
    let ids = r.array!.compactMap { $0["worktree"]?.string }
    // The list also holds the project's main workspace (the repo itself): write into the first fan-out one.
    let first = try await c.call("worktree.list", .obj(["repoId": .string(repo.id)])).array?.first { $0["id"]?.string == ids.first }
    try "x\n".write(toFile: (first?["path"]?.string ?? "") + "/new.txt", atomically: true, encoding: .utf8)
    let cmp = try await c.call("fanout.compare", .obj(["ids": .array(ids.map { .string($0) })]))
    #expect(cmp.array?.count == 2)
    #expect(cmp.array![0]["files"]?.int == 1)
}

final class NoteBox: @unchecked Sendable {
    private let l = NSLock(); private var out: [String: String] = [:]
    func add(_ m: String, _ p: JSONValue) {
        guard m == "event.output", let id = p["session"]?.string, let b = p["data"]?.string, let d = Data(base64Encoded: b) else { return }
        l.lock(); out[id, default: ""] += String(decoding: d, as: UTF8.self); l.unlock()
    }
    func output(_ id: String) -> String { l.lock(); defer { l.unlock() }; return out[id] ?? "" }
}

@Test func aiFeatures() async throws {
    let root = tmp(); let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    // A fake agent: asks the trust question, then echoes whatever prompt it gets.
    try FileManager.default.createDirectory(at: root.appendingPathComponent("agents"), withIntermediateDirectories: true)
    let script = #"printf 'Do you trust the files in this folder? '; read -r a; echo TRUST-OK; while read -r l; do echo "GOT:$l"; done"#
    try JSONEncoder().encode(AgentManifest(id: "fake", name: "Fake", command: "/bin/zsh", args: ["-c", script],
        autoAnswers: [.init(pattern: "(?i)do you trust", input: "\r")], resumeArgs: [])).write(to: root.appendingPathComponent("agents/fake.json"))

    let repoPath = try makeRepo()
    try ".env.secret\nnode_modules\n".write(toFile: repoPath + "/.gitignore", atomically: true, encoding: .utf8)
    try "SECRET=1\n".write(toFile: repoPath + "/.env.secret", atomically: true, encoding: .utf8)
    try ".env.*\n".write(toFile: repoPath + "/.worktreeinclude", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: repoPath + "/node_modules/x", withIntermediateDirectories: true)
    try "shared: node_modules\n".write(toFile: repoPath + "/.krill.yaml", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], cwd: repoPath); try Git.run(["commit", "-qm", "cfg"], cwd: repoPath)

    let c = try RPCClient(socket: root.appendingPathComponent("krill.sock").path)
    let box = NoteBox(); c.onNotification = { m, p in box.add(m, p) }
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(repoPath)]), as: Repo.self)
    let r = try await c.call("task.create", .obj(["repoId": .string(repo.id), "prompt": "Add a dark mode toggle to settings", "agent": "fake"]))
    let wt = try r["worktree"]!.decode(Worktree.self), s = try r["session"]!.decode(Session.self)
    #expect(wt.branch.contains("dark") || wt.branch.contains("mode") || wt.branch.contains("toggle"))
    #expect(FileManager.default.fileExists(atPath: wt.path + "/.env.secret"))              // .worktreeinclude
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: wt.path + "/node_modules")) != nil)   // shared
    _ = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    #expect(try await waitFor(15) { box.output(s.id).contains("TRUST-OK") })                // auto-answer
    #expect(try await waitFor(15) { box.output(s.id).contains("GOT:Add a dark mode toggle") })   // launch prompt
    #expect(try await waitFor(10) { (try await c.call("session.list", as: [Session].self)).first { $0.id == s.id }?.title.isEmpty == false })

    _ = try await c.call("session.rename", .obj(["id": .string(s.id), "title": "Mine"]))
    #expect(try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.title == "Mine")

    let ctx = try await c.call("session.context", .obj(["id": .string(s.id)]))
    #expect(ctx.string?.contains("GOT:") == true)

    let h: Session = try await c.call("session.handoff", .obj(["id": .string(s.id), "agent": "fake"]), as: Session.self)
    _ = try await c.call("session.attach", .obj(["id": .string(h.id)]))
    #expect(try await waitFor(20) { box.output(h.id).contains("GOT:Read ") })
    #expect(h.worktreeId == wt.id && h.title.contains("handoff"))

    let rs: Session = try await c.call("session.restart", .obj(["id": .string(s.id)]), as: Session.self)
    #expect(rs.cwd == s.cwd && rs.argv == s.argv && rs.title == "Mine")
}

@Test func hibernateAndWake() async throws {
    let root = tmp(); let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("agents"), withIntermediateDirectories: true)
    // A resumable fake agent: prints whether it was resumed.
    try JSONEncoder().encode(AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", #"echo "STARTED $*"; sleep 30"#, "x"], resumeArgs: ["--resume"]))
        .write(to: root.appendingPathComponent("agents/sleepy.json"))
    let c = try RPCClient(socket: root.appendingPathComponent("krill.sock").path)
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self)
    let wt: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "h", "setup": false]), as: Worktree.self)
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "sleepy"]), as: Session.self)
    _ = try await c.call("config.set", .obj(["hibernateMinutes": .double(0.03)]))   // ~2 s
    #expect(try await waitFor(15) { try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .hibernated })
    // Opening it again resumes the same session id with the resume flag.
    let box = NoteBox(); c.onNotification = { m, p in box.add(m, p) }
    _ = try await c.call("config.set", .obj(["hibernateMinutes": 0]))
    _ = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    #expect(try await waitFor(10) { box.output(s.id).contains("STARTED") && box.output(s.id).contains("--resume") })
    #expect(try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status != .hibernated)
}

@Test func chatRoundTrip() async throws {
    // A fake `claude` speaking stream-json: echoes each user message back as text + one tool call + a result.
    let bin = tmp()
    let fake = """
    #!/bin/zsh
    echo '{"type":"system","subtype":"init","model":"fake-model","session_id":"s1"}'
    while read -r line; do
      t=$(printf '%s' "$line" | sed -E 's/.*"text":"([^"]*)".*/\\1/')
      echo "{\\"type\\":\\"assistant\\",\\"message\\":{\\"content\\":[{\\"type\\":\\"text\\",\\"text\\":\\"echo: $t\\"},{\\"type\\":\\"tool_use\\",\\"id\\":\\"t1\\",\\"name\\":\\"Bash\\",\\"input\\":{\\"command\\":\\"ls\\"}}]}}"
      echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.001,"num_turns":1}'
    done
    """
    try fake.write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
    chmod(bin.appendingPathComponent("claude").path, 0o755)
    setenv("PATH", bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)

    let root = tmp(); let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let c = try RPCClient(socket: root.appendingPathComponent("krill.sock").path)
    let box = ChatBox(); c.onNotification = { m, p in if m == "event.chat", let l = p["line"]?.string { box.add(l) } }
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self)
    let wt: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "chat", "setup": false]), as: Worktree.self)
    let id = try #require(try await c.call("chat.start", .obj(["worktreeId": .string(wt.id)]))["id"]?.string)
    _ = try await c.call("chat.send", .obj(["id": .string(id), "text": "hello"]))
    #expect(try await waitFor(10) { box.all.contains { $0.contains("echo: hello") } })
    let events = box.all.flatMap { ChatEvent.parse(Data($0.utf8)) }
    #expect(events.contains(.started(model: "fake-model", sessionId: "s1")))
    #expect(events.contains(.tool(id: "t1", name: "Bash", summary: "Bash ls")))
    #expect(events.contains(.finished(ok: true, costUSD: 0.001, turns: 1)))
    let hist = try await c.call("chat.history", .obj(["id": .string(id)])).array ?? []
    #expect(hist.count >= 4)   // init, user, assistant, result
    _ = try await c.call("chat.stop", .obj(["id": .string(id)]))
}

final class ChatBox: @unchecked Sendable {
    private let l = NSLock(); private var lines: [String] = []
    func add(_ s: String) { l.lock(); lines.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return lines }
}

/// Every project has a main workspace on the repo itself; "+" makes "Workspace N" instantly; the main one can't be deleted.
@Test func workspacesMainAndInstant() async throws {
    let root = tmp(); let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let c = try RPCClient(socket: root.appendingPathComponent("krill.sock").path)
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self)
    let list: [Worktree] = try await c.call("worktree.list", .obj(["repoId": .string(repo.id)]), as: [Worktree].self)
    let main = list.first { $0.path == repo.path }
    #expect(main != nil)
    let w: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "setup": false]), as: Worktree.self)
    #expect(w.note == "Workspace 2" && w.branch == "ws-2")
    await #expect(throws: RPCError.self) { _ = try await c.call("worktree.remove", .obj(["id": .string(main?.id ?? "")])) }
}

/// A workspace is a desk in the project folder: no branch, no checkout; closing one leaves the files, the last stays.
@Test func desksShareTheProjectFolder() async throws {
    let root = tmp(); let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let c = try RPCClient(socket: root.appendingPathComponent("krill.sock").path)
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self)
    let desk: Worktree = try await c.call("workspace.create", .obj(["repoId": .string(repo.id)]), as: Worktree.self)   // before any list
    let first = try #require(try await c.call("worktree.list", .obj(["repoId": .string(repo.id)]), as: [Worktree].self).first { $0.id != desk.id })
    #expect(first.note == "Workspace 1" && first.path == repo.path)
    #expect(desk.note == "Workspace 2" && desk.path == repo.path && desk.branch == first.branch)
    #expect(!Git.branchExists(repo.path, "ws-2"))
    _ = try await c.call("worktree.remove", .obj(["id": .string(desk.id)]))
    #expect(FileManager.default.fileExists(atPath: repo.path))
    await #expect(throws: RPCError.self) { _ = try await c.call("worktree.remove", .obj(["id": .string(first.id)])) }
}

/// Summaries start from the agent's own last reply, not the terminal around it.
@Test func lastReplyFromTranscript() throws {
    let f = tmp().appendingPathComponent("t.jsonl")
    let lines = [
        #"{"type":"user","message":{"content":"hi"}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"First answer."}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed the parser tests."}]}}"#,
        #"{"type":"system","subtype":"stop"}"#
    ]
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
    #expect(Daemon.lastReply(transcript: f) == "Fixed the parser tests.")
}
