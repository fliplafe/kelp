import Foundation
import os

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
        /// It printed more than the run's `limit` on stdout or stderr: that stream here is only its first `limit` bytes.
        public var truncated: Bool
    }

    /// What `run` keeps of each stream unless told otherwise: far past any answer git, gh or ssh give Kelp, short of a
    /// runaway (a diff of a regenerated dataset, a `cat` of a log) taking the daemon's memory.
    public static let outputLimit = 64 << 20

    /// The daemon's connection reader while it applies an in-order call (`Handled.inOrder`), and a quick one
    /// (`Handled.quick`), which takes no turn behind slow programs: no program runs there. `run` refuses inside `body`, and
    /// the call fails instead of stalling.
    public static func quickOnly<T>(_ body: () throws -> T) rethrows -> T {
        let d = Thread.current.threadDictionary
        d[quickOnlyKey] = true
        defer { d[quickOnlyKey] = nil }
        return try body()
    }
    private static let quickOnlyKey = "dev.kelp.subprocess.quickOnly"

    /// `argv[0]` is a path. `env` is the whole environment. Past `limit` bytes a stream is still read to its end, so the
    /// program ends as it would have (its exit status, whatever it does besides printing), but the rest is dropped and
    /// the output is `truncated`: a caller that needs all of it fails then, one that can show a part says so.
    public static func run(_ argv: [String], cwd: String, env: [String: String], stdin: Data? = nil, timeLimit: TimeInterval,
                           limit: Int = outputLimit) throws -> Output {
        if Thread.current.threadDictionary[quickOnlyKey] != nil {
            let name = argv.first.map { ($0 as NSString).lastPathComponent } ?? "A program"
            throw RPCError.internalError("\(name) can't run from a quick or in-order call: it would hold up others.")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv.first ?? "/usr/bin/false")
        p.arguments = Array(argv.dropFirst())
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = env
        let out = Reader(limit), err = Reader(limit), inp = stdin.map { _ in Pipe() }
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
        return Output(status: ended ? p.terminationStatus : -1, stdout: out.data, stderr: err.data, timedOut: timedOut,
                      truncated: out.truncated || err.truncated)
    }

    /// `run` without holding the caller's thread (for async callers: the app's main actor, the cooperative pool).
    public static func run(_ argv: [String], cwd: String, env: [String: String], stdin: Data? = nil, timeLimit: TimeInterval,
                           limit: Int = outputLimit) async throws -> Output {
        try await withCheckedThrowingContinuation { c in
            Thread.detachNewThread { c.resume(with: Result { try run(argv, cwd: cwd, env: env, stdin: stdin, timeLimit: timeLimit, limit: limit) }) }
        }
    }

    /// SIGTERM to `pid` and everything it started, children first (found before the parent goes, while they're still its),
    /// then SIGKILL to whatever is left after 2 s: one that ignores SIGTERM would hold the pipes for good.
    public static func stopTree(_ pid: pid_t) {
        let all = tree(pid)
        for p in all.reversed() { kill(p, SIGTERM) }
        killLater(all, after: 2)
    }

    /// SIGKILL after `delay` to those of `pids` still running: the same processes, by their start time, not ones that
    /// were given a pid of theirs since.
    public static func killLater(_ pids: [pid_t], after delay: TimeInterval) {
        let born = pids.map { ($0, started($0)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            for (p, t) in born where t != nil && started(p) == t { kill(p, SIGKILL) }
        }
    }

    /// When `pid` started (µs since 1970); nil once there's no such process.
    public static func started(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// `pid` and its descendants, parents before children.
    public static func tree(_ pid: pid_t) -> [pid_t] {
        var kids = [pid_t](repeating: 0, count: 256)
        let n = Int(proc_listchildpids(pid, &kids, Int32(kids.count * MemoryLayout<pid_t>.size)))
        return [pid] + kids.prefix(max(0, n)).filter { $0 > 0 }.flatMap(tree)
    }

    /// One pipe, read to its end on a thread of its own; its first `limit` bytes kept.
    private final class Reader: Sendable {
        let pipe = Pipe()
        let done = DispatchSemaphore(value: 0)
        let limit: Int
        private struct Kept { var data = Data(), truncated = false }
        private let kept = OSAllocatedUnfairLock(initialState: Kept())
        init(_ limit: Int) { self.limit = limit }
        var data: Data { kept.withLock { $0.data } }
        var truncated: Bool { kept.withLock { $0.truncated } }
        func start() {
            let fd = pipe.fileHandleForReading.fileDescriptor
            Thread.detachNewThread { [pipe, kept, done, limit] in
                // read(2), not FileHandle.read(upToCount:): that one waits for the whole count, so output a lingering
                // child keeps the pipe open behind would never arrive.
                var buf = [UInt8](repeating: 0, count: 1 << 16), room = limit
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n > 0 {
                        // Past the limit it's still read (a full pipe would stop the program) and dropped.
                        let keep = min(n, room)
                        room -= keep
                        if keep > 0 { let chunk = Data(buf[0..<keep]); kept.withLock { $0.data.append(chunk) } }
                        if keep < n { kept.withLock { $0.truncated = true } }
                    } else if n < 0, errno == EINTR { continue } else { break }
                }
                withExtendedLifetime(pipe) { done.signal() }
            }
        }
    }
}
