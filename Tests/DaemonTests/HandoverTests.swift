import Foundation
import Testing
import Core
@testable import Daemon
import TestSupport

private let readAndEcho = "echo before; while read l; do echo got-$l; done"

/// An update hands each running session to the next kelpd (`handOver`, then `start(adopting:)`; kelpd execs in between):
/// the same program goes on, its history comes along, typing reaches it, and its end is still seen.
@Test func runningSessionsCarryOnIntoTheNextDaemon() async throws {
    let (d, c, root) = try daemon(); defer { d.stop() }
    // A daemon hosted in another program (this one) won't exec it.
    await #expect(throws: RPCError.self) { try await c.call(DaemonUpgrade()) }
    let s = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    #expect(try await waitFor { d.sessions.existing(s.id)?.tail(4096).range(of: Data("before".utf8)) != nil })

    let next = try Daemon(root: root)
    try next.start(adopting: try #require(d.handOver())); defer { next.stop() }
    #expect(d.sessions.existing(s.id) == nil)
    let c2 = try client(root)
    #expect(try await c2.call(DaemonInfo()).liveSessions == 1)
    #expect(kill(s.pid, 0) == 0 && next.sessions.existing(s.id)?.snapshot.pid == s.pid)
    #expect(try await c2.call(SessionRead(id: s.id)).contains("before"))
    _ = try await c2.call(SessionWrite(id: s.id, text: "x\n"))
    #expect(try await waitFor { try await c2.call(SessionRead(id: s.id)).contains("got-x") })
    _ = try await c2.call(SessionWrite(id: s.id, text: "\u{4}"))   // ⌃D: read ends, and so does the program
    #expect(try await waitFor { try await c2.call(SessionList()).first { $0.id == s.id }?.status == .exited })
}

/// kelpd itself: `daemon.upgrade` runs the binary at its path again in the same process, and the session's program never
/// stops.
@Test func kelpdUpgradesInPlace() async throws {
    let kelp = try #require(ProcessInfo.processInfo.environment["KELP_TRAMPOLINE"])
    let root = tmp()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: kelp).deletingLastPathComponent().appendingPathComponent("kelpd")
    p.environment = ProcessInfo.processInfo.environment.merging(["KELP_HOME": root.path]) { $1 }
    try p.run()
    defer { if p.isRunning { p.terminate() } }   // only the kelpd this test started
    func connected() async throws -> RPCClient? {
        for _ in 0..<50 { if let c = try? client(root) { return c }; try await Task.sleep(for: .milliseconds(100)) }
        return nil
    }
    let c = try #require(try await connected())
    let s = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    #expect(try await waitFor { try await c.call(SessionRead(id: s.id)).contains("before") })

    // A program the old run started that isn't a session (a git, a language server) ends after the exec: reaped, not a zombie.
    let stray = Task { try? await c.call(ProcessRun(argv: ["/bin/sleep", "1"])) }
    #expect(try await waitFor { children(of: p.processIdentifier).contains { name($0) == "sleep" } })
    _ = try await c.call(DaemonUpgrade())
    #expect(try await waitFor { (try? await c.call(Ping())) == nil })   // this connection ended with the old run
    _ = await stray.value
    let c2 = try #require(try await connected())
    let info = try await c2.call(DaemonInfo())
    #expect(info.pid == Int(p.processIdentifier) && info.liveSessions == 1 && p.isRunning)
    #expect(kill(s.pid, 0) == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("handover.json").path))
    _ = try await c2.call(SessionWrite(id: s.id, text: "x\n"))
    #expect(try await waitFor { try await c2.call(SessionRead(id: s.id)).contains("got-x") })
    #expect(try await waitFor(5) { children(of: p.processIdentifier).allSatisfy { name($0) != "sleep" && !isZombie($0) } })
    _ = try await c2.call(DaemonShutdown())
    #expect(try await waitFor { !p.isRunning && kill(s.pid, 0) != 0 })
}

/// `pid`'s children, zombies included.
private func children(of pid: pid_t) -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 256)
    let n = Int(proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    return Array(pids.prefix(max(0, n)))
}

/// Ended, and not reaped by its parent.
private func isZombie(_ pid: pid_t) -> Bool {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    return sysctl(&mib, 4, &info, &size, nil, 0) == 0 && size > 0 && info.kp_proc.p_stat == SZOMB
}

/// Its program's name while it runs ("" once it has ended).
private func name(_ pid: pid_t) -> String {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return "" }
    return withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}
