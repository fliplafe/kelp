import Foundation
import os
import Core

/// What one kelpd hands the next when an update replaces it (`daemon.upgrade`): the socket, the home's lock and each
/// running session's terminal, all left open across exec in the same process. The programs stay this process's children
/// and never notice; what they print meanwhile waits in their terminals.
public struct Handover: Codable, Sendable {
    /// `modes` and `bytes`: its history, as the last `bytes` of its log in those terminal modes.
    struct Session: Codable, Sendable { var id: String, pid: Int32, fd: Int32, modes: String, bytes: Int }
    var socket: Int32, lock: Int32
    var sessions: [Session]
    // A newer kelpd reads what an older one wrote: fields are only ever added, as optionals.

    /// The file `kelpd --adopt` names, read and removed. Nil if it can't be read: then the lock this process still holds
    /// makes the start fail, and the sessions end with it, as after a crash.
    public static func take(_ path: String) -> Handover? {
        defer { unlink(path) }
        do { return try JSONDecoder().decode(Handover.self, from: Data(contentsOf: URL(fileURLWithPath: path))) } catch {
            Log.start.fault("couldn't read what the last kelpd handed over: \(error)")
            return nil
        }
    }

    /// What the kelpd before this one still ran besides the sessions (a git, a language server it was stopping) is this
    /// process's now: reaped once it ends instead of staying a zombie. Called before this run starts a program of its own,
    /// whose exit is its runner's to read.
    public func reapOthers() {
        let kept = Set(sessions.map(\.pid))
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        for pid in pids.prefix(max(0, n)) where !kept.contains(pid) {
            Thread.detachNewThread { var st: Int32 = 0; while waitpid(pid, &st, 0) < 0 && errno == EINTR {} }
        }
    }

    /// Exec in place (`POSIX_SPAWN_SETEXEC`) of `exe --adopt file`: the same process, pid and children; of its files only
    /// stdio and these stay open. Returns only by throwing.
    func exec(_ exe: String, file: String) throws {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        for fd in [0, 1, 2, socket, lock] + sessions.map(\.fd) { posix_spawn_file_actions_addinherit_np(&fa, fd) }
        let argv = ([exe, "--adopt", file].map { strdup($0) } + [nil]) as [UnsafeMutablePointer<CChar>?]
        let env = (ProcessInfo.processInfo.environment.map { strdup("\($0)=\($1)") } + [nil]) as [UnsafeMutablePointer<CChar>?]
        defer { (argv + env).forEach { free($0) } }
        let rc = posix_spawn(nil, exe, &fa, &attr, argv, env)
        throw RPCError.internalError("couldn't run \(exe): \(String(cString: strerror(rc)))")
    }
}
