import Foundation
import Testing
@testable import Core
import TestSupport

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

@Test func lineBufferSplitsAcrossChunks() {
    var b = LineBuffer()
    #expect(b.append(Data("{\"a\":".utf8)).isEmpty)
    let lines = b.append(Data("1}\n{\"b\":2}\nrest".utf8))
    #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}"])
    #expect(b.append(Data("\n\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["rest", ""])
    // A long line in small reads comes out whole, once.
    let long = String(repeating: "x", count: 100_000)
    var got: [Data] = []
    for chunk in Data((long + "\nnext").utf8).chunked(8192) { got += b.append(chunk) }
    #expect(got.map { String(decoding: $0, as: UTF8.self) } == [long])
    #expect(String(decoding: b.takeRemainder(), as: UTF8.self) == "next")
}

private extension Data {
    func chunked(_ n: Int) -> [Data] { stride(from: 0, to: count, by: n).map { self[$0..<Swift.min($0 + n, count)] } }
}

@Test func jsonValueKeepsEachType() throws {
    let text = #"{"n":null,"b":true,"i":3,"d":2.5,"s":"x","a":[1,"y",false],"o":{"k":[]}}"#
    let v = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    #expect(v == .object(["n": .null, "b": .bool(true), "i": .int(3), "d": .double(2.5), "s": .string("x"),
                          "a": .array([.int(1), .string("y"), .bool(false)]), "o": .object(["k": .array([])])]))
    #expect(v["i"]?.number == 3 && v["d"]?.number == 2.5 && v["s"]?.number == nil)   // either kind of number, nothing else
}

@Test func callTimesOutWhenNoReplyComes() async throws {
    let path = NSTemporaryDirectory() + "kelp-timeout-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer { close(server); unlink(path) }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)
    defer { close(peer) }
    await #expect(throws: RPCError.self) { try await client.call("usage.get", timeout: 0.2) }
    // The late reply finds nobody waiting (no second resume), and the next call still gets its own.
    let late = try Wire.line(JSONValue.obj(["id": 1, "result": .null])), next = try Wire.line(JSONValue.obj(["id": 2, "result": "ok"]))
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { Unix.writeAll(peer, late + next) }
    #expect(try await client.call("ping", timeout: 5).string == "ok")
}

/// A socket someone still answers on isn't taken over; a stale one (its owner gone) is.
@Test func listenLeavesALiveSocketAlone() throws {
    let path = NSTemporaryDirectory() + "kelp-live-\(getpid()).sock"
    let first = try Unix.listen(path)
    #expect(throws: (any Error).self) { try Unix.listen(path) }
    close(first)
    // The file is still there, nobody behind it: taken over. (A process being started elsewhere in the test run holds a
    // copy of every fd for a moment, so not necessarily on the first try.)
    var again: Int32 = -1
    for _ in 0..<100 where again < 0 {
        again = (try? Unix.listen(path)) ?? -1
        if again < 0 { usleep(20_000) }
    }
    #expect(again >= 0)
    close(again); unlink(path)
}

@Test func jsonValueRoundTrip() throws {
    let v = try JSONValue.from(RPCRequest(id: 1, method: "x", params: .object(["k": .string("v")])))
    #expect(v["method"]?.string == "x")
    #expect(v["params"]?["k"]?.string == "v")
}

/// Typed methods put the JSON on the wire that the hand-written calls they replaced did, and read today's answers.
@Test func typedMethodsKeepTheWireFormat() throws {
    #expect(try DaemonInfo().params() == nil)
    #expect(try StateGet(prefix: "").params() == .obj(["prefix": ""]))
    #expect(try StateGet(key: "k").params() == .obj(["key": "k"]))
    #expect(try StateSet(key: "k", value: .array(["a"])).params() == .obj(["key": "k", "value": .array(["a"])]))
    #expect(try StateSet(key: "k", value: nil).params() == .obj(["key": "k"]))   // a missing value deletes, as null does
    #expect(try SessionRename(id: "s", title: "t").params() == .obj(["id": "s", "title": "t"]))
    #expect(try SessionContextWindow(id: "s").params() == .obj(["id": "s"]))
    #expect(try WorktreeNote(id: "w", note: "n").params() == .obj(["id": "w", "note": "n"]))

    let info = try JSONValue.obj(["path": "/k/kelpd", "binaryMTime": 1_760_000_000, "pid": 7, "liveSessions": 2]).decode(DaemonInfo.Result.self)
    #expect(info.path == "/k/kelpd" && info.binaryMTime == 1_760_000_000 && info.liveSessions == 2)   // a whole double arrives as an int
    #expect(try JSONValue.obj(["path": "/k", "pid": 7, "liveSessions": 0]).decode(DaemonInfo.Result.self).binaryMTime == nil)
    #expect(try JSONValue.obj(["used": 10, "window": 100]).decode(SessionContextWindow.Result.self) == .init(used: 10, window: 100))
    #expect(try JSONValue.null.decode(SessionContextWindow.Result.self) == nil)
    #expect(try JSONValue.from(Done()) == .null)
    _ = try JSONValue.null.decode(Done.self)
}

@Test func ghosttyConfigParse() {
    let c = GhosttyConfig.parse("# comment\nbackground = #1e1e2e\nforeground=cdd6f4\nfont-family = \"JetBrains Mono\"\nfont-size = 14\npalette = 1=#f38ba8\n")
    #expect(c.background == "#1e1e2e" && c.foreground == "cdd6f4" && c.fontFamily == "JetBrains Mono" && c.fontSize == 14 && c.palette[1] == "#f38ba8")
    #expect(GhosttyConfig.rgb("#ff0000")! == (1, 0, 0))
}

@Test func knownErrorsCarryTheirFix() {
    #expect(FixRecipes.fix(for: "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools)") == .init(command: "xcode-select --install", blocking: true))
    #expect(FixRecipes.fix(for: "You have not agreed to the Xcode license agreements.")?.blocking == true)
    #expect(FixRecipes.fix(for: "fatal: The current branch x has no upstream branch.")?.command == "git push -u origin HEAD")
    #expect(FixRecipes.fix(for: "everything is fine") == nil)
}

@Test func aSocketIsPrivateToItsOwner() throws {
    let dir = NSTemporaryDirectory() + "kelp-priv-\(getpid())"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let path = dir + "/k.sock"
    let fd = try Unix.listen(path)
    defer { close(fd); try? FileManager.default.removeItem(atPath: dir) }
    func mode(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? Int) ?? -1 }
    #expect(mode(path) == 0o600)
    #expect(mode(dir) == 0o700)   // our own folder is closed off, so nothing could reach the socket before its chmod
}

@Test func aSharedFolderIsNotChangedForASocket() throws {
    let before = ((try? FileManager.default.attributesOfItem(atPath: "/tmp"))?[.posixPermissions] as? Int) ?? 0
    let path = "/tmp/kelp-shared-\(getpid()).sock"
    let fd = try Unix.listen(path)
    defer { close(fd); unlink(path) }
    #expect(((try? FileManager.default.attributesOfItem(atPath: "/tmp"))?[.posixPermissions] as? Int) == before)   // sticky and not ours: left alone
}

@Test func onlyOurOwnProcessesAreAcceptedOnTheSocket() throws {
    let path = NSTemporaryDirectory() + "kelp-peer-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer { close(server); unlink(path) }
    let client = try Unix.connect(path)
    let peer = accept(server, nil, nil)
    defer { close(client); close(peer) }
    #expect(Unix.peerIsUs(peer))
    #expect(!Unix.peerIsUs(-1))   // not a connection at all: refused, not trusted
}

@Test func keychainSetUpdatesInPlaceAndDeleteRemoves() throws {
    _ = TestIsolation.root   // never the real keys, even if one was inherited
    let account = "kelp-test-\(UUID().uuidString)"
    defer { Keychain.delete(account) }
    #expect(Keychain.get(account) == nil)
    try Keychain.set("one", account: account)
    #expect(Keychain.get(account) == "one")
    try Keychain.set("two", account: account)   // the second set updates, it doesn't fail on the existing item
    #expect(Keychain.get(account) == "two")
    Keychain.delete(account)
    #expect(Keychain.get(account) == nil)
}

/// The app installs its handlers after connecting (with awaits in between): a daemon that drops first must still be noticed.
@Test func aCloseHandlerInstalledAfterTheDropStillRuns() async throws {
    let path = NSTemporaryDirectory() + "kelp-late-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer { close(server); unlink(path) }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)
    close(peer)                                                       // the daemon goes away before anyone listens for that
    await #expect(throws: (any Error).self) { _ = try await client.call("ping", timeout: 5) }   // the reader has seen the close
    let told = Flag()
    client.onClose = { told.set() }
    #expect(told.value)                                               // installed late, run at once
}

@Test func notificationsReachAHandlerSetWhileReading() async throws {
    let path = NSTemporaryDirectory() + "kelp-note-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer { close(server); unlink(path) }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)
    defer { close(peer) }
    let got = Flag()
    client.onNotification = { m, _ in if m == "event.test" { got.set() } }
    Unix.writeAll(peer, try Wire.line(RPCRequest(id: nil, method: "event.test", params: nil)))
    for _ in 0..<50 where !got.value { try await Task.sleep(for: .milliseconds(20)) }
    #expect(got.value)
}

private final class Flag: @unchecked Sendable {   // the bool under lock
    private let lock = NSLock(); private var on = false
    func set() { lock.withLock { on = true } }
    var value: Bool { lock.withLock { on } }
}

/// The app doesn't ignore SIGPIPE: writing to a daemon that went away must fail, not kill the process (the test would die).
@Test func writingToAGoneDaemonFailsInsteadOfKillingTheProcess() throws {
    let path = NSTemporaryDirectory() + "kelp-pipe-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer { close(server); unlink(path) }
    let old = signal(SIGPIPE, SIG_DFL)   // as in the app: SIGPIPE would end the process
    defer { signal(SIGPIPE, old) }
    let fd = try Unix.connect(path)
    defer { close(fd) }
    close(accept(server, nil, nil))      // the daemon side goes away
    let big = Data(repeating: 0x41, count: 1 << 20)
    var failed = false
    for _ in 0..<4 where !failed { failed = !Unix.writeAll(fd, big) }
    #expect(failed)                      // the write reports it; we're still here
}

/// A client closed while its reader waits must not read the next connection's replies (closing the fd under the reader
/// let the number be reused). Many rounds of close-then-reconnect: every new connection gets its own answer.
@Test func aClosedClientNeverReadsTheNextConnectionsReplies() async throws {
    let path = NSTemporaryDirectory() + "kelp-reuse-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer { close(server); unlink(path) }
    for round in 0..<50 {
        let old = try RPCClient(socket: path)
        let oldPeer = accept(server, nil, nil)
        old.close()
        let fresh = try RPCClient(socket: path)
        let peer = accept(server, nil, nil)
        DispatchQueue.global().async { Unix.writeAll(peer, (try? Wire.line(JSONValue.obj(["id": 1, "result": .string("r\(round)")]))) ?? Data()) }
        #expect(try await fresh.call("ping", timeout: 5).string == "r\(round)")
        fresh.close(); close(peer); close(oldPeer)
    }
}

@Test func lockedKeepsEveryChangeFromManyThreads() async {
    let n = Locked(0)
    await withTaskGroup(of: Void.self) { g in for _ in 0..<1000 { g.addTask { n.withLock { $0 += 1 } } } }
    #expect(n.current == 1000)
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
