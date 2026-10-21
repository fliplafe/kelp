import Foundation

/// Runs a program to its end and collects what it printed: git, gh, ssh, `ps`, an extension's command. One way for all
/// of them, so each gets the same care:
/// - the pipes are read on threads of their own as data arrives (never a thread of the cooperative pool, which a blocked
///   read could starve, and never a full pipe that stops the program);
/// - stdin is written alongside, and a program that exits unread fails that write instead of raising SIGPIPE;
/// - past `timeLimit` the program is stopped with everything it started (`stopTree`): its children hold the pipes too;
/// - a child that outlives it holding the pipes (a daemon it started) doesn't hold up the result.
public enum Subprocess {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        /// Stopped at the time limit (its status is then the signal's).
        public var timedOut: Bool
    }

    /// `argv[0]` is a path. `env` is the whole environment.
    public static func run(_ argv: [String], cwd: String, env: [String: String], stdin: Data? = nil, timeLimit: TimeInterval) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv.first ?? "/usr/bin/false")
        p.arguments = Array(argv.dropFirst())
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = env
        let out = Reader(), err = Reader(), inp = stdin.map { _ in Pipe() }
        p.standardOutput = out.pipe; p.standardError = err.pipe; p.standardInput = inp ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }   // set before it starts: one that exits at once isn't missed
        try p.run()
        out.start(); err.start()
        if let inp, let stdin {
            let w = inp.fileHandleForWriting
            _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)
            Thread.detachNewThread { try? w.write(contentsOf: stdin); try? w.close() }
        }
        var timedOut = false, ended = true
        if exited.wait(timeout: .now() + timeLimit) == .timedOut {
            timedOut = true
            stopTree(p.processIdentifier)
            // SIGKILL comes 2 s after SIGTERM; one stuck in the kernel (a hung network mount) may outlast even that.
            ended = exited.wait(timeout: .now() + 5) == .success
        }
        // What's still in the pipes arrives at once; only a child holding them open would make this wait run out.
        _ = out.done.wait(timeout: .now() + 2); _ = err.done.wait(timeout: .now() + 2)
        // Its status only once it has exited: asking a Process still running raises, and would take the daemon down.
        return Output(status: ended ? p.terminationStatus : -1, stdout: out.data, stderr: err.data, timedOut: timedOut)
    }

    /// `run` without holding the caller's thread (for async callers: the app's main actor, the cooperative pool).
    public static func run(_ argv: [String], cwd: String, env: [String: String], stdin: Data? = nil, timeLimit: TimeInterval) async throws -> Output {
        try await withCheckedThrowingContinuation { c in
            Thread.detachNewThread { c.resume(with: Result { try run(argv, cwd: cwd, env: env, stdin: stdin, timeLimit: timeLimit) }) }
        }
    }

    /// SIGTERM to `pid` and everything it started, children first (found before the parent goes, while they're still its),
    /// then SIGKILL to whatever is left after 2 s: one that ignores SIGTERM would hold the pipes for good.
    /// Limit: a pid could be reused within those 2 s; start times would rule that out.
    public static func stopTree(_ pid: pid_t) {
        let all = tree(pid)
        for p in all.reversed() { kill(p, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { for p in all where kill(p, 0) == 0 { kill(p, SIGKILL) } }
    }

    /// `pid` and its descendants, parents before children.
    public static func tree(_ pid: pid_t) -> [pid_t] {
        var kids = [pid_t](repeating: 0, count: 256)
        let n = Int(proc_listchildpids(pid, &kids, Int32(kids.count * MemoryLayout<pid_t>.size)))
        return [pid] + kids.prefix(max(0, n)).filter { $0 > 0 }.flatMap(tree)
    }

    /// One pipe, read to its end on a thread of its own.
    private final class Reader: Sendable {
        let pipe = Pipe()
        let done = DispatchSemaphore(value: 0)
        private let collected = Locked(Data())
        var data: Data { collected.current }
        func start() {
            let fd = pipe.fileHandleForReading.fileDescriptor
            Thread.detachNewThread { [pipe, collected, done] in
                // read(2), not FileHandle.read(upToCount:): that one waits for the whole count, so output a lingering
                // child keeps the pipe open behind would never arrive.
                var buf = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n > 0 { collected.withLock { $0.append(contentsOf: buf[0..<n]) } } else if n < 0, errno == EINTR { continue } else { break }
                }
                withExtendedLifetime(pipe) { done.signal() }
            }
        }
    }
}
