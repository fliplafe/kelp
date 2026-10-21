import Foundation
import Testing
import Core
@testable import Daemon

/// Real tmux, on a server of the tests' own (TMUX_TMPDIR is the test folder): the user's sessions are never seen.
/// Each test ends only its own session, as they share that server.
private let tmux = try? LoginPath.resolve("tmux")

private func tmuxSessions(_ c: RPCClient, _ wt: Worktree) async throws -> [String] { try await c.call(TmuxList(worktreeId: wt.id)).map(\.name) }
private func end(_ session: String) {
    _ = try? Subprocess.run([tmux ?? "", "kill-session", "-t", "=" + session], cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 10)
}

/// A tmux tab outlives its daemon: it comes back paused, opening it attaches to the same tmux session (what ran there is
/// still on screen), and closing the tab leaves the session running in tmux.
@Test(.enabled(if: tmux != nil, "tmux isn't installed")) func tmuxTerminalComesBackToItsSession() async throws {
    let w = try await world(); defer { end("kelp_test") }
    let wt = try await firstDesk(w)
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "tmux": "kelp.test"]), as: Session.self)
    #expect(s.agent == "shell" && Tmux.session(s.argv) == "kelp_test" && s.title == "tmux kelp_test")
    func screen(_ c: RPCClient) async throws -> String { try await c.call("session.read", .obj(["id": .string(s.id)])).string ?? "" }
    #expect(try await waitFor(10) { try await tmuxSessions(w.c, wt).contains("kelp_test") })
    _ = try await w.c.call("session.write", .obj(["id": .string(s.id), "text": "echo marker-$((6*7))\r"]))
    #expect(try await waitFor(10) { try await screen(w.c).contains("marker-42") })

    w.d.stop()
    let d = try Daemon(root: w.root); try d.start(); defer { d.stop() }
    let c = try client(w.root)
    #expect(try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .hibernated)
    #expect(try await tmuxSessions(c, wt).contains("kelp_test"))   // detached, not ended
    _ = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    #expect(try await waitFor(10) { try await screen(c).contains("marker-42") })   // tmux redraws its screen for the new client

    _ = try await c.call("session.kill", .obj(["id": .string(s.id)]))
    #expect(try await waitFor(10) { try await c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status == .exited })
    #expect(try await tmuxSessions(c, wt).contains("kelp_test"))
}

/// A remote project's tmux is the host's: the tab runs tmux there (not a login shell) and the list is read there.
@Test(.enabled(if: tmux != nil, "tmux isn't installed")) func remoteTmuxRunsOnTheHost() async throws {
    _ = localSSH; defer { end("far") }
    let (d, c, _) = try daemon(); defer { d.stop() }
    let repo: Repo = try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(try makeRepo())]), as: Repo.self)
    let wt = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    _ = try await c.call("session.create", .obj(["worktreeId": .string(wt.id), "tmux": "far"]))
    #expect(try await waitFor(15) { try await tmuxSessions(c, wt).contains("far") })
}
