import Foundation
import Testing
import Core
import GitKit
@testable import Daemon

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
    try "x\n".write(toFile: (try await c.call("worktree.list", .obj(["repoId": .string(repo.id)])).array![0]["path"]!.string!) + "/new.txt", atomically: true, encoding: .utf8)
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
