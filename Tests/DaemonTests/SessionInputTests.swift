import Foundation
import os
import Testing
import Core
import Agents
@testable import Daemon

/// A send to a paused agent that can't wake says so: the reply waits for the wake. It used to answer OK at once and log
/// the failure, so `kelp send` and the app showed nothing.
@Test func aSendWhoseWakeFailsSaysSo() async throws {
    let w = try await world(agents: [AgentManifest(id: "gone", name: "Gone", command: "/bin/zsh", args: ["-c", "echo ready; exec cat"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let wt = try await desk(w, "wake-fails")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "gone"))
    try await hibernate(after: 0.03, w.c)   // ~2 s
    #expect(try await waitFor(15) { try await w.c.call(SessionList()).first { $0.id == s.id }?.status == .hibernated })
    try await hibernate(after: 0, w.c)
    try FileManager.default.removeItem(at: w.root.appendingPathComponent("agents/gone.json"))   // nothing to wake it with
    await #expect(throws: RPCError.self) { _ = try await w.c.call(SessionSend(id: s.id, text: "hello")) }
}

/// A send with its Return never lands on a line the user is half-way through typing: it would send their line with it.
/// It's refused until they send or clear it; text that isn't sent (a reference) still goes in beside theirs.
@Test func aSendDoesntSendTheUsersHalfWrittenLine() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "half")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "stty -echo; echo ready; exec cat"))
    func screen() async throws -> String { try await w.c.call(SessionRead(id: s.id)) }
    func keys(_ k: String) async throws { _ = try await w.c.call(SessionWrite(id: s.id, base64: Data(k.utf8).base64EncodedString())) }
    #expect(try await waitFor(10) { try await screen().contains("ready") })
    try await Task.sleep(for: .seconds(2.5))   // started up: drawn and quiet, sends go straight in
    try await keys("half")
    await #expect(throws: RPCError.self) { _ = try await w.c.call(SessionSend(id: s.id, text: "hello")) }
    _ = try await w.c.call(SessionSend(id: s.id, text: " ref", enter: false))
    try await keys("\u{15}")   // ⌃U: their line is gone (the terminal's kill character for cat, too)
    _ = try await w.c.call(SessionSend(id: s.id, text: "hello"))
    #expect(try await waitFor(10) { try await screen().contains("hello") })
    #expect(!(try await screen()).contains("half"))
}

/// Keys the user presses while a send waits for its Return (0.3 s, so the agent takes the text as typed) land after
/// that Return: they used to go in between, and the Return sent them with the prompt ("hellox").
@Test func keysPressedDuringASendComeAfterItsReturn() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "keys-after")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "stty -echo; echo ready; exec cat"))
    func screen() async throws -> String { try await w.c.call(SessionRead(id: s.id)) }
    #expect(try await waitFor(10) { try await screen().contains("ready") })
    try await Task.sleep(for: .seconds(2.5))   // started up: the send is typed now
    _ = try await w.c.call(SessionSend(id: s.id, text: "hello"))
    _ = try await w.c.call(SessionWrite(id: s.id, base64: Data("x\r".utf8).base64EncodedString()))   // within its 0.3 s
    func lines() async throws -> [String] { try await screen().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } }
    #expect(try await waitFor(10) { try await lines().contains("x") })
    #expect(try await lines().suffix(2) == ["hello", "x"])
}

/// What the user typed and hasn't sent, followed from their keys.
@Test func theUsersUnsentLineIsFollowedFromTheirKeys() {
    var s = LiveSession.State(record: Session(cwd: "/", command: "cat"), manifest: AgentManifest(id: "custom", name: "Custom", command: "/bin/cat"),
                              logSize: 0, callbacks: .init())
    func keys(_ k: String) -> String? { s.noteTyping(Data(k.utf8)) }
    _ = keys("fix the"); #expect(s.typing == "fix the")
    _ = keys("\u{7F}\u{7F}"); #expect(s.typing == "fix t")
    _ = keys("\u{17}"); #expect(s.typing == "fix ")   // ⌃W
    _ = keys("x\u{1B}\u{7F}"); _ = keys("\u{1B}\u{7F}"); #expect(s.typing.isEmpty)   // "x", then ⌥⌫ twice
    _ = keys("\u{1B}[A"); #expect(s.typing.isEmpty)   // an arrow
    _ = keys("\u{1B}[200~two\rlines\u{1B}[201~"); #expect(s.typing == "two\nlines")   // a paste's newlines don't send it
    _ = keys("\u{3}"); #expect(s.typing.isEmpty)   // ⌃C
    #expect(keys("fix the login bug\r") == "fix the login bug")   // sent: the first prompt, which names the session
    #expect(s.typing.isEmpty)
    #expect(keys("and the tests\r") == nil)
    // As the kitty keyboard protocol sends them (Claude Code turns it on): ⌃U, ⌥⌫ (not its release), ⇧Return, Return.
    _ = keys("half"); _ = keys("\u{1B}[117;5u"); #expect(s.typing.isEmpty)
    _ = keys("half"); _ = keys("\u{1B}[1075::117;5u"); #expect(s.typing.isEmpty)   // ⌃U on a Cyrillic layout
    _ = keys("ab cd"); _ = keys("\u{1B}[127;3u"); _ = keys("\u{1B}[127;3:3u"); #expect(s.typing == "ab ")
    _ = keys("\u{1B}[13;2u"); #expect(s.typing == "ab ")
    _ = keys("\u{1B}[13u"); #expect(s.typing.isEmpty)
}

/// Sessions that ended over a week ago go, records and logs, and logs nobody's record names; paused and newer ones stay.
@Test func endedSessionsGoAfterAWeek() throws {
    let (d, _, root) = try daemon(); defer { d.stop() }
    let week = Sessions.keepEnded, history = root.appendingPathComponent("history"), fm = FileManager.default
    try fm.createDirectory(at: history, withIntermediateDirectories: true)
    let old = Session(cwd: "/tmp", command: "x", status: .exited, createdAt: Date() - week - 3600)
    var recent = Session(cwd: "/tmp", command: "x", status: .exited, createdAt: Date() - week - 3600); recent.statusAt = Date() - 3600
    let paused = Session(cwd: "/tmp", command: "x", status: .hibernated, createdAt: Date() - week * 4)
    for s in [old, recent, paused] { try d.store.save(s); try Data("out".utf8).write(to: history.appendingPathComponent("\(s.id).log")) }
    let orphan = history.appendingPathComponent("orphan.log"), fresh = history.appendingPathComponent("fresh.log")
    try Data().write(to: orphan); try Data().write(to: fresh)
    try fm.setAttributes([.modificationDate: Date() - 2 * 86400], ofItemAtPath: orphan.path)
    d.sessions.pruneEnded()
    #expect(try d.store.sessions().map(\.id).sorted() == [recent.id, paused.id].sorted())
    #expect(!fm.fileExists(atPath: history.appendingPathComponent("\(old.id).log").path))
    #expect(fm.fileExists(atPath: history.appendingPathComponent("\(recent.id).log").path))
    #expect(!fm.fileExists(atPath: orphan.path))
    #expect(fm.fileExists(atPath: fresh.path))   // a session being created writes its log before its record
}

/// An agent asked for while the daemon stops isn't started: its pause has passed, so it would run on after the daemon
/// with nobody to pause it, and a wake later would start a second copy.
@Test func nothingStartsWhileTheDaemonStops() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "stopping")
    w.d.sessions.pauseAll()
    await #expect(throws: RPCError.self) { _ = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "exec sleep 30")) }
    #expect(try w.d.store.sessions().isEmpty)
    #expect(w.d.sessions.live.all.isEmpty)
}

/// A pause is the record's last word: a status change that read the record just before it, still on its way to the
/// database, isn't saved over it. It was, and the agent, gone, stayed "working" and could never be woken.
@Test func aPauseIsntWrittenOverByAnOlderStatus() async throws {
    let w = try await world(agents: [AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", "echo ready; exec cat"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let wt = try await desk(w, "pausing")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "sleepy"))
    let ls = try #require(w.d.sessions.live[s.id])
    let gate = DispatchSemaphore(value: 0)
    ls.inOrder { let old = ls.snapshot; gate.wait(); w.d.sessions.publish(old) }   // held until the pause had its say
    let paused = OSAllocatedUnfairLock(initialState: false)
    Thread.detachNewThread { try? w.d.sessions.pauseSessions(of: wt.id); paused.withLock { $0 = true } }
    try await Task.sleep(for: .milliseconds(500))
    gate.signal()
    #expect(try await waitFor(10) { paused.withLock { $0 } })
    await withCheckedContinuation { c in ls.inOrder { c.resume() } }   // whatever was queued is saved by now
    #expect(try w.d.store.session(s.id)?.status == .hibernated)
}
