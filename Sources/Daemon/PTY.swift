import Foundation
import Core

/// A child process on a pseudo-terminal. The daemon owns this, so the process outlives any UI.
public final class PTY: @unchecked Sendable {
    public let pid: pid_t
    private let master: Int32
    private var source: DispatchSourceRead?
    private let q = DispatchQueue(label: "krill.pty")
    private var exited = false

    public var onOutput: (@Sendable (Data) -> Void)?
    public var onExit: (@Sendable (Int32) -> Void)?

    public init(argv: [String], cwd: String, env: [String: String], cols: UInt16 = 120, rows: UInt16 = 32) throws {
        var m: Int32 = 0, s: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &ws) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var nameBuf = [CChar](repeating: 0, count: 128)
        ptsname_r(m, &nameBuf, nameBuf.count)
        let slavePath = String(cString: nameBuf)
        // Keep our end of the slave open until the child has it: closing the last fd resets the tty (size becomes 0×0).

        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addchdir_np(&fa, cwd)
        posix_spawn_file_actions_addopen(&fa, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fa, 0, 1)
        posix_spawn_file_actions_adddup2(&fa, 0, 2)
        var attr: posix_spawnattr_t? = nil
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
        if let tramp = Self.trampoline {
            // krill __ctty: claims the tty as controlling terminal, then execs the agent (PATH from the child env).
            let targv = ([strdup(tramp), strdup("__ctty")] + cargv.dropLast() + [nil]) as [UnsafeMutablePointer<CChar>?]
            rc = posix_spawn(&pid, tramp, &fa, &attr, targv, cenv)
            free(targv[0]); free(targv[1])
        } else {
            rc = posix_spawnp(&pid, argv[0], &fa, &attr, cargv, cenv)
        }
        close(s)
        guard rc == 0 else { close(m); throw POSIXError(.init(rawValue: rc) ?? .ENOENT) }
        self.pid = pid; self.master = m

        let src = DispatchSource.makeReadSource(fileDescriptor: m, queue: q)
        src.setEventHandler { [weak self] in self?.drain() }
        src.resume()
        source = src
        let wq = DispatchQueue(label: "krill.pty.wait")
        wq.async { [weak self] in
            var st: Int32 = 0
            waitpid(pid, &st, 0)
            self?.q.async { self?.finish(st) }
        }
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(master, &buf, buf.count)
        if n > 0 { onOutput?(Data(buf[0..<n])) }
        else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { source?.cancel(); source = nil }
    }

    private func finish(_ status: Int32) {
        guard !exited else { return }
        exited = true
        // Flush anything still buffered in the kernel.
        var buf = [UInt8](repeating: 0, count: 65536)
        let fl = fcntl(master, F_GETFL); _ = fcntl(master, F_SETFL, fl | O_NONBLOCK)
        while true { let n = read(master, &buf, buf.count); if n <= 0 { break }; onOutput?(Data(buf[0..<n])) }
        source?.cancel(); source = nil
        close(master)
        onExit?(status)
    }

    /// The `krill` CLI next to the daemon binary.
    nonisolated(unsafe) static var trampoline: String? = {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let p = dir.appendingPathComponent("krill").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }()

    static let scrubbed = ["CLAUDECODE", "CLAUDE_CODE_", "CODEX_SANDBOX", "CODEX_THREAD", "KRILL_SESSION", "TERM_PROGRAM", "ITERM_", "VSCODE_"]

    public func write(_ d: Data) { Unix.writeAll(master, d) }
    public func resize(cols: UInt16, rows: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &ws)
    }
    public func kill() { Darwin.kill(-pid, SIGHUP); Darwin.kill(pid, SIGTERM) }
}
