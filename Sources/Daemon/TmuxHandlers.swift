import Foundation
import Core

/// tmux where a workspace's sessions run: on this Mac, or on a remote project's host (see `Tmux`).
extension Daemon {
    /// `tmux <args>`, on the host for a remote project through its login shell, as its terminals are (tmux is on that PATH).
    func tmux(_ args: [String], cwd: String, timeLimit: TimeInterval = 30) throws -> Subprocess.Output {
        let argv = try RemoteHost.of(cwd).map { [RemoteHost.ssh] + $0.sshArgs(tty: false) + [$0.command(["tmux"] + args)] }
            ?? [LoginPath.resolve("tmux")] + args
        var env = ProcessInfo.processInfo.environment; env["PATH"] = childPath
        return try Subprocess.run(argv, cwd: NSHomeDirectory(), env: env, timeLimit: timeLimit)
    }

    /// Ends the tmux session a terminal of Kelp's own ran in, in the background (over ssh it can take a while).
    func endOwnTmux(_ s: Session) {
        guard let name = Tmux.session(s.argv), Tmux.isOwn(name) else { return }
        DispatchQueue.global(qos: .utility).async { [self] in _ = try? tmux(["kill-session", "-t", "=" + name], cwd: s.cwd) }
    }

    /// The first program running in the session's panes other than their shells.
    func tmuxBusy(_ name: String, cwd: String) -> String? {
        guard let r = try? tmux(["list-panes", "-s", "-t", "=" + name, "-F", "#{pane_current_command}"], cwd: cwd, timeLimit: 2), r.status == 0 else { return nil }
        return String(decoding: r.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init).first { !Tmux.shells.contains($0) }
    }
}

extension TmuxList: Handled {
    func handle(_ d: Daemon) throws -> Result {
        let r = try d.tmux(["list-sessions", "-F", Tmux.format], cwd: d.cwd(forWorktree: worktreeId).path)
        let err = String(decoding: r.stderr, as: UTF8.self)
        if r.status == 0 { return Tmux.parse(String(decoding: r.stdout, as: UTF8.self)) }
        if Tmux.noServer(err) { return [] }
        let why = err.trimmingCharacters(in: .whitespacesAndNewlines)
        throw RPCError.invalidParams(r.timedOut ? "tmux didn't answer." : why.isEmpty ? "tmux list-sessions failed (exit code \(r.status))." : why)
    }
}
