import Foundation
import Core

/// What runs under each session's PTY, read with ps and lsof when asked (nothing samples in the background):
/// the dev servers a workspace started (ports) and what each session costs (CPU, memory).
extension Daemon {
    struct Port: Codable { var port: Int, pid: Int32, command: String, session: String }
    struct Usage: Codable { var session: String, cpu: Double, memory: Int, processes: Int }

    /// Every process under a live session's PTY, by pid → session id; `only` limits it to one workspace.
    private func sessionProcesses(worktree only: String? = nil) -> (owner: [Int32: String], rows: [Int32: (cpu: Double, rss: Int)]) {
        let roots = lock.withLock { live.values.filter { only == nil || $0.snapshot.worktreeId == only }.map { ($0.pty.pid, $0.snapshot.id) } }
        guard !roots.isEmpty else { return ([:], [:]) }
        var children: [Int32: [Int32]] = [:], rows: [Int32: (cpu: Double, rss: Int)] = [:]
        for line in (Self.run(["/bin/ps", "-axo", "pid=,ppid=,pcpu=,rss="], path: "/bin:/usr/bin", timeout: 3) ?? "").split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ")
            guard f.count == 4, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            children[ppid, default: []].append(pid)
            rows[pid] = (Double(f[2]) ?? 0, (Int(f[3]) ?? 0) * 1024)
        }
        var owner: [Int32: String] = [:]
        for (pid, sid) in roots {
            var stack = [pid]
            while let p = stack.popLast() { owner[p] = sid; stack += children[p] ?? [] }
        }
        return (owner, rows)
    }

    func ports(worktree wid: String) -> [Port] {
        let owner = sessionProcesses(worktree: wid).owner
        guard !owner.isEmpty else { return [] }
        var out: [Port] = [], pid: Int32 = 0, cmd = ""
        // Only the sessions' processes (-a: and): a system-wide lsof walks every process on the Mac, every 3 s while Ports
        // shows. lsof exits 1 when one of them ended since ps (an agent's git, a build step), with the others' ports
        // printed: through sh, so that isn't a failure. The pids are numbers.
        let pids = owner.keys.map(String.init).joined(separator: ",")
        let lsof = "/usr/sbin/lsof -nP -a -p \(pids) -iTCP -sTCP:LISTEN -Fpcn; exit 0"
        for line in (Self.run(["/bin/sh", "-c", lsof], path: "/bin:/usr/bin", timeout: 4) ?? "").split(whereSeparator: \.isNewline) {
            switch line.first {
            case "p": pid = Int32(line.dropFirst()) ?? 0
            case "c": cmd = String(line.dropFirst())
            case "n":
                guard let sid = owner[pid], let port = line.split(separator: ":").last.flatMap({ Int($0) }),
                      !out.contains(where: { $0.port == port }) else { continue }
                out.append(Port(port: port, pid: pid, command: cmd, session: sid))
            default: break
            }
        }
        return out.sorted { $0.port < $1.port }
    }

    /// CPU (ps's %, summed over the session's processes; 100 = one core) and resident memory per live session.
    func usage() -> [Usage] {
        let (owner, rows) = sessionProcesses()
        var by: [String: Usage] = [:]
        for (pid, sid) in owner {
            guard let r = rows[pid] else { continue }
            var u = by[sid] ?? Usage(session: sid, cpu: 0, memory: 0, processes: 0)
            u.cpu += r.cpu; u.memory += r.rss; u.processes += 1
            by[sid] = u
        }
        return by.values.filter { $0.memory > 0 }.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }   // 0: already gone
    }
}
