import Foundation
import Core

/// A child process on a pseudo-terminal. The daemon owns this, so the process outlives any UI.
/// Once the program has exited its fd and pid are gone for good: they may already name another session's terminal or
/// another process, so nothing is written to the one or signalled at the other after that.
public final class PTY: @unchecked Sendable {
    public let pid: pid_t
    private let primaryFD: Int32
    private var source: DispatchSourceRead?
    private let q = DispatchQueue(label: "kelp.pty")
    private var exited = false
    private let io = NSLock()     // `closed`: the primaryFD is closed under it, so no write lands in a reused fd
    private let life = NSLock()   // `reaped`: set before the pid is reaped, so no signal reaches a recycled one
    private var closed = false, reaped = false, started = false

    public var onOutput: (@Sendable (Data) -> Void)?
    public var onExit: (@Sendable (Int32) -> Void)?

    /// `trampoline`: the `kelp` binary that makes the PTY the child's controlling terminal (nil spawns directly).
    public init(argv: [String], cwd: String, env: [String: String], cols: UInt16 = 120, rows: UInt16 = 32, trampoline: String? = PTY.trampoline) throws {
        var m: Int32 = 0, s: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &ws) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var nameBuf = [CChar](repeating: 0, count: 128)
        ptsname_r(m, &nameBuf, nameBuf.count)
        let secondaryPath = String(cString: nameBuf)
        // Keep our end of the slave open until the child has it: closing the last fd resets the tty (size becomes 0×0).

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addchdir_np(&fa, cwd)
        posix_spawn_file_actions_addopen(&fa, 0, secondaryPath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fa, 0, 1)
        posix_spawn_file_actions_adddup2(&fa, 0, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Reset signal state: the child must not inherit our ignored/blocked signals (SIGHUP/SIGTERM would be no-ops).
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        // Don't leak the environment of whatever started the daemon (e.g. an agent's session markers) into new sessions.
        var e = ProcessInfo.processInfo.environment.filter { k, _ in !Self.scrubbed.contains { k.hasPrefix($0) } }.merging(env) { $1 }
        e["TERM"] = "xterm-256color"; e["COLORTERM"] = "truecolor"
        let cargv = (argv.map { strdup($0) } + [nil]) as [UnsafeMutablePointer<CChar>?]
        let cenv = (e.map { strdup("\($0)=\($1)") } + [nil]) as [UnsafeMutablePointer<CChar>?]
        defer { cargv.forEach { free($0) }; cenv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc: Int32
        if let tramp = trampoline {
            // kelp __ctty: claims the tty as controlling terminal, then execs the agent (PATH from the child env).
            let targv = ([strdup(tramp), strdup("__ctty")] + cargv.dropLast() + [nil]) as [UnsafeMutablePointer<CChar>?]
            rc = posix_spawn(&pid, tramp, &fa, &attr, targv, cenv)
            free(targv[0]); free(targv[1])
        } else {
            rc = posix_spawnp(&pid, argv[0], &fa, &attr, cargv, cenv)
        }
        close(s)
        guard rc == 0 else { close(m); throw POSIXError(.init(rawValue: rc) ?? .ENOENT) }
        self.pid = pid; self.primaryFD = m
    }

    /// Starts reading the output and waiting for the exit. Set `onOutput` / `onExit` first: a program that prints (or
    /// fails) at once would otherwise lose that.
    public func start() {
        let first = io.withLock { () -> Bool in
            guard !started, !closed else { return false }
            started = true; return true
        }
        guard first else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: primaryFD, queue: q)
        src.setEventHandler { [weak self] in self?.drain() }
        q.sync { source = src }
        src.resume()
        let pid = pid
        DispatchQueue(label: "kelp.pty.wait").async { [weak self] in
            // Wait without reaping: while it's a zombie its pid can't be anyone else's, so `reaped` goes up first.
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
            self?.life.withLock { self?.reaped = true }
            var st: Int32 = 0
            while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
            guard let pty = self else { return }
            let status = st
            pty.q.async { pty.finish(status) }
        }
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(primaryFD, &buf, buf.count)
        if n > 0 { onOutput?(Data(buf[0..<n])) }
        else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { source?.cancel(); source = nil }
    }

    private func finish(_ status: Int32) {
        guard !exited else { return }
        exited = true
        // Flush anything still buffered in the kernel.
        var buf = [UInt8](repeating: 0, count: 65536)
        let fl = fcntl(primaryFD, F_GETFL); _ = fcntl(primaryFD, F_SETFL, fl | O_NONBLOCK)
        while true { let n = read(primaryFD, &buf, buf.count); if n <= 0 { break }; onOutput?(Data(buf[0..<n])) }
        hangUp()
        onExit?(status)
    }

    private func hangUp() {
        io.withLock {
            guard !closed else { return }
            closed = true; source?.cancel(); source = nil; close(primaryFD)
        }
    }

    /// Dropped while its program runs (the limits probe quits that way): hang up the terminal. A controlling process
    /// waits in exit until its output is read, and nobody reads it any more.
    deinit { hangUp() }

    /// The `kelp` CLI next to the daemon binary.
    public static let trampoline: String? = {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let p = dir.appendingPathComponent("kelp").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }()

    static let scrubbed = ["CLAUDECODE", "CLAUDE_CODE_", "CODEX_SANDBOX", "CODEX_THREAD", "KELP_SESSION", "TERM_PROGRAM", "ITERM_", "VSCODE_"]

    /// Typing into the program; dropped once it has exited (the fd may be another terminal's by then).
    public func write(_ d: Data) { io.withLock { if !closed { Unix.writeAll(primaryFD, d) } } }

    /// The program in the foreground when it isn't the one the PTY started (a shell running `npm run dev`, vim…).
    public var foregroundProgram: String? {
        let pg = io.withLock { closed ? -1 : tcgetpgrp(primaryFD) }
        guard pg > 0, pg != pid else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(pg, &name, UInt32(name.count)) > 0 ? String(cString: name) : "a program"
    }
    public func resize(cols: UInt16, rows: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        io.withLock { if !closed { _ = ioctl(primaryFD, TIOCSWINSZ, &ws) } }
    }
    public func kill() { signal { Darwin.kill(-$0, SIGHUP); Darwin.kill($0, SIGTERM) } }

    /// kill(), then SIGKILL the group if it's still there after `grace` seconds (some TUIs ignore SIGTERM).
    public func terminate(grace: TimeInterval = 2) {
        kill()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in   // keeps the PTY, and so `reaped`, until then
            signal { if Darwin.kill($0, 0) == 0 { Darwin.kill(-$0, SIGKILL); Darwin.kill($0, SIGKILL) } }
        }
    }

    /// `f(pid)` while the pid is still this program's.
    private func signal(_ f: (pid_t) -> Void) { life.withLock { if !reaped { f(pid) } } }
}
