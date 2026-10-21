import Foundation
import os
import Testing
import Core
@testable import Daemon

/// Every notification a client heard, in order.
private final class Heard: Sendable {
    private let all = OSAllocatedUnfairLock<[(String, JSONValue)]>(initialState: [])
    func listen(_ c: RPCClient) { c.onNotification = { [self] m, p in all.withLock { $0.append((m, p)) } } }
    func events<E: RPCEvent>(_: E.Type) -> [E] { all.withLock { $0 }.filter { $0.0 == E.name }.compactMap { try? $0.1.decode(E.self) } }
}

/// A watched workspace's git comes at once, then again when its files change — and not again while nothing does.
/// Before, every panel had a watcher of its own and asked git again itself.
@Test func aWatchedWorkspacesGitIsPushedWhenItsFilesChangeAndOnlyThen() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await firstDesk(w)
    let heard = Heard(); heard.listen(w.c)
    w.c.notify(WatchStart(.git, wt.id))
    #expect(try await waitFor(10) { heard.events(GitEvent.self).first?.changes == [] })
    try "new\n".write(toFile: wt.path + "/added.txt", atomically: true, encoding: .utf8)
    #expect(try await waitFor(10) { heard.events(GitEvent.self).last?.changes?.map(\.path) == ["added.txt"] })
    let seen = heard.events(GitEvent.self).count
    try await Task.sleep(for: .milliseconds(1500))   // nothing changes: nothing is pushed
    #expect(heard.events(GitEvent.self).count == seen)
}

/// Two clients watching one topic share one reader; it stops after the last one stops watching or goes away.
@Test func watchersShareOneReaderThatStopsWithTheLast() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await firstDesk(w)
    let a = try client(w.root), b = try client(w.root)
    let ha = Heard(), hb = Heard(); ha.listen(a); hb.listen(b)
    a.notify(WatchStart(.ports, wt.id)); b.notify(WatchStart(.ports, wt.id))
    #expect(try await waitFor(10) { !ha.events(PortsEvent.self).isEmpty && !hb.events(PortsEvent.self).isEmpty })
    #expect(w.d.watches.running == 1)
    a.notify(WatchStop(.ports, wt.id))
    _ = try await b.call(Ping())   // after b's own connection was taken; a's stop is on its way
    #expect(try await waitFor(5) { w.d.watches.running == 1 })
    b.close()
    #expect(try await waitFor(5) { w.d.watches.running == 0 })
    let key = Watches.Key(topic: .ports, key: wt.id)
    let reads = w.d.watches.reads.withLock { $0[key] ?? 0 }
    try await Task.sleep(for: .seconds(4))   // a ports reader reads every 3 s while anyone watches
    #expect(w.d.watches.reads.withLock { $0[key] ?? 0 } == reads)
}

/// Projects and workspaces come as records when they change, including a desk the list itself added, and removals say
/// so: the app keeps its lists from these instead of reading them again on "something changed".
@Test func recordsArePushedAsTheyChange() async throws {
    let w = try await world(); defer { w.d.stop() }
    let heard = Heard(); heard.listen(w.c)
    let wt = try await firstDesk(w)
    _ = try await w.c.call(WorktreeNote(id: wt.id, note: "Renamed"))
    #expect(try await waitFor(5) { heard.events(Worktree.self).contains { $0.id == wt.id && $0.note == "Renamed" } })
    let other = try await w.c.call(RepoAdd(path: try makeRepo()))   // its first desk is made by the desk sync
    #expect(try await waitFor(5) { heard.events(Repo.self).contains { $0.id == other.id } })
    #expect(try await waitFor(5) { heard.events(Worktree.self).contains { $0.repoId == other.id } })
    let desk = try await w.c.call(WorkspaceCreate(repoId: w.repo.id))
    _ = try await w.c.call(WorktreeRemove(id: desk.id))
    #expect(try await waitFor(5) { heard.events(RemovedEvent.self).contains { $0.worktree == desk.id } })
    _ = try await w.c.call(RepoRemove(id: other.id))
    #expect(try await waitFor(5) { heard.events(RemovedEvent.self).contains { $0.repo == other.id } })
}

/// A session deleted for good (here with its workspace) says so too: the app drops it without reading the list again.
@Test func aDeletedSessionIsPushedAsRemoved() async throws {
    let w = try await world(); defer { w.d.stop() }
    let heard = Heard(); heard.listen(w.c)
    let desk = try await w.c.call(WorkspaceCreate(repoId: w.repo.id))
    let s = try await w.c.call(SessionCreate(worktreeId: desk.id, command: "exec cat"))
    _ = try await w.c.call(WorktreeRemove(id: desk.id))
    #expect(try await waitFor(5) { heard.events(RemovedEvent.self).contains { $0.session == s.id } })
}
