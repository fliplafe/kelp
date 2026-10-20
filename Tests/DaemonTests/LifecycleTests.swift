import Foundation
import Testing
import Core
import GitKit
@testable import Daemon

/// A daemon on a fresh home, a client, and the first workspace of one project.
private func project() async throws -> (Daemon, RPCClient, Worktree, URL) {
    let root = tmp(); let d = try Daemon(root: root); try d.start()
    let c = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self)
    let w = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    return (d, c, w, root)
}

private func status(_ c: RPCClient, _ id: String) async throws -> AgentStatus? {
    try await c.call("session.list", as: [Session].self).first { $0.id == id }?.status
}

/// An ended session leaves the live set (its fd and pid are nobody's now) but its tab still shows what it printed,
/// and a hook that comes late neither wakes nor revives it.
@Test func endedSessionLeavesButKeepsItsScreen() async throws {
    let (d, c, w, _) = try await project(); defer { d.stop() }
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": "echo last-words"]), as: Session.self)
    #expect(try await waitFor { try await status(c, s.id) == .exited })
    #expect(try await waitFor { d.existing(s.id) == nil })
    let h = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    let screen = String(bytes: Data(base64Encoded: h["history"]?.string ?? "") ?? Data(), encoding: .utf8) ?? ""
    #expect(screen.contains("last-words"))
    _ = try await c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))
    #expect(try await status(c, s.id) == .exited)
}

/// Restart replaces the session: the old one's exit, which comes after, doesn't put its record (or log) back.
@Test func restartLeavesNoGhost() async throws {
    let (d, c, w, root) = try await project(); defer { d.stop() }
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 30"]), as: Session.self)
    let r: Session = try await c.call("session.restart", .obj(["id": .string(s.id)]), as: Session.self)
    try await Task.sleep(for: .seconds(1))
    let ids = try await c.call("session.list", as: [Session].self).map(\.id)
    #expect(ids.contains(r.id) && !ids.contains(s.id))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("history/\(s.id).log").path))
}

/// Removing a project stops its agents: none keeps working (and spending) out of sight.
@Test func removingAProjectEndsItsAgents() async throws {
    let (d, c, w, _) = try await project(); defer { d.stop() }
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 30"]), as: Session.self)
    _ = try await c.call("repo.remove", .obj(["id": .string(w.repoId)]))
    #expect(try await waitFor { kill(s.pid, 0) != 0 })
    #expect(try await c.call("session.list", as: [Session].self).allSatisfy { $0.id != s.id })
}

/// Numbers out of range (a typo on the CLI: `kelp terminal read <id> -1`) are clamped, not a crash that ends every agent.
@Test func outOfRangeNumbersAreClamped() async throws {
    let (d, c, w, _) = try await project(); defer { d.stop() }
    d.agentHomes = (tmp(), tmp())
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": "echo hi; sleep 30", "cols": -3, "rows": 70000]),
                                      as: Session.self)
    _ = try await c.call("session.read", .obj(["id": .string(s.id), "bytes": -1]))
    _ = try await c.call("session.context", .obj(["id": .string(s.id), "bytes": -1]))
    _ = try await c.call("session.resize", .obj(["id": .string(s.id), "cols": -5, "rows": 99999]))
    _ = try await c.call("history.list", .obj(["limit": -1]))
    await #expect(throws: RPCError.self) { try await c.call("ports.stop", .obj(["worktreeId": .string(w.id), "pid": .int(Int.max)])) }
    #expect(try await c.call("ping").string == "pong")
}

/// A second daemon for the same home (launchd's KeepAlive, a CLI that couldn't connect) bows out instead of taking the
/// socket and marking the first one's agents paused.
@Test func oneDaemonPerHome() async throws {
    let root = tmp(); let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    #expect(throws: (any Error).self) { try Daemon(root: root).start() }
    #expect(try await RPCClient(socket: root.appendingPathComponent("kelp.sock").path).call("ping").string == "pong")
}

/// `.kelp-remote` is Kelp's own marker in its own folder; one committed to a repository is just a file.
@Test func remoteMarkerCountsOnlyInKelpsFolder() throws {
    let root = tmp(); _ = try Daemon(root: root)
    let marker = try JSONEncoder().encode(RemoteHost(host: "evil.example", path: "/x"))
    let cloned = try makeRepo()
    try marker.write(to: URL(fileURLWithPath: cloned + "/" + RemoteHost.marker))
    #expect(RemoteHost.of(cloned) == nil)
    let mine = root.appendingPathComponent("remote/box/app")
    try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
    try marker.write(to: mine.appendingPathComponent(RemoteHost.marker))
    #expect(RemoteHost.of(mine.path)?.host == "evil.example")
    try JSONEncoder().encode(RemoteHost(host: "-oProxyCommand=touch /tmp/x", path: "/x")).write(to: mine.appendingPathComponent(RemoteHost.marker))
    #expect(RemoteHost.of(mine.path) == nil)
    #expect(Array(RemoteHost(host: "box", path: "/x").sshArgs(tty: false).suffix(2)) == ["--", "box"])
}

/// JSON-RPC ids may be strings; a line that isn't a request still gets an answer when it has an id.
@Test func stringIdsComeBackAsSent() async throws {
    let root = tmp(); let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path); defer { close(fd) }
    var tv = timeval(tv_sec: 5, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    Unix.writeAll(fd, Data((#"{"jsonrpc":"2.0","id":"a1","method":"ping"}"# + "\n" + #"{"jsonrpc":"2.0","id":7}"# + "\n").utf8))
    var lb = LineBuffer(), lines: [JSONValue] = [], buf = [UInt8](repeating: 0, count: 4096)
    while lines.count < 2 {
        let n = read(fd, &buf, buf.count); guard n > 0 else { break }
        lines += lb.append(Data(buf[0..<n])).compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }
    #expect(lines.contains { $0["id"] == "a1" && $0["result"] == "pong" })
    #expect(lines.contains { $0["id"] == 7 && $0["error"]?["code"] == -32600 })
}

/// Big requests and replies on one connection, many at once: each line arrives whole (a Unix socket takes 8 KB at a
/// time, and a reply written in pieces used to get another one in between — both were dropped and the calls hung).
@Test func bigMessagesDontMixOnTheWire() async throws {
    let root = tmp(); let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let c = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
    let big = JSONValue.obj(["blob": .string(String(repeating: "x", count: 300_000))])
    _ = try await c.call("ui.publish", .obj(["state": big]))
    try await withThrowingTaskGroup(of: Bool.self) { g in
        for i in 0..<40 {
            g.addTask {
                if i % 5 == 0 { _ = try await c.call("ui.publish", .obj(["state": big]), timeout: 15); return true }
                return try await c.call("ui.state", timeout: 15) == big
            }
        }
        for try await ok in g { #expect(ok) }
    }
}

/// `kelp attach` gets the history first and the live output after it, never a live chunk ahead of the history.
@Test func attachSendsHistoryBeforeLiveOutput() async throws {
    let (d, c, w, root) = try await project(); defer { d.stop() }
    let count = "i=0; while [ $i -lt 300000 ]; do i=$((i+1)); echo n$i; done; sleep 30"
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": .string(count)]), as: Session.self)
    try await Task.sleep(for: .milliseconds(300))
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path); defer { close(fd) }
    var tv = timeval(tv_sec: 2, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    Unix.writeAll(fd, try Wire.line(RPCRequest(id: nil, method: "session.stream", params: .obj(["id": .string(s.id)]))))
    var got = Data(), buf = [UInt8](repeating: 0, count: 65536)
    let end = Date().addingTimeInterval(1.5)
    while Date() < end { let n = read(fd, &buf, buf.count); if n <= 0 { break }; got.append(contentsOf: buf[0..<n]) }
    let lines = (String(bytes: got, encoding: .utf8) ?? "").split(whereSeparator: \.isNewline).dropFirst().dropLast()   // the ends may be cut
    let numbers = lines.compactMap { Int($0.drop { !$0.isNumber }) }
    #expect(numbers.count > 100)
    #expect(zip(numbers, numbers.dropFirst()).allSatisfy { $0 < $1 })
}

/// A session's log keeps what it printed across a pause (see hibernateAndWake) and stops growing at `logLimit`.
@Test func historyLogStaysBounded() async throws {
    let (d, c, w, root) = try await project(); defer { d.stop() }
    let flood = "head -c 9000000 /dev/zero | tr '\\0' x; echo; echo tail-mark; sleep 30"
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(w.id), "command": .string(flood)]), as: Session.self)
    #expect(try await waitFor(30) { try await c.call("session.read", .obj(["id": .string(s.id), "bytes": 200])).string?.contains("tail-mark") == true })
    let size = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("history/\(s.id).log").path)[.size] as? Int ?? 0
    #expect(size > 0 && size <= LiveSession.logLimit)
}

/// A short command that prints more than a pipe holds still comes back whole.
@Test func runReadsLongOutput() {
    #expect(Daemon.run(["/bin/sh", "-c", "head -c 200000 /dev/zero | tr '\\0' y"], path: "/bin:/usr/bin", timeout: 5)?.count == 200_000)
}
