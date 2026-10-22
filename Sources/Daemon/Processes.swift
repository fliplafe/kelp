import Foundation
import Core

/// What runs under each session's PTY, read with ps and lsof when asked (nothing samples in the background):
/// the dev servers a workspace started (ports) and what each session costs (CPU, memory).
extension Daemon {
    typealias Port = PortsList.Port
    typealias Usage = SessionUsage.Usage

    /// Every process under a live session's PTY, by pid → session id; `only` limits it to one workspace.
    private func sessionProcesses(worktree only: String? = nil) -> (owner: [Int32: String], rows: [Int32: (cpu: Double, rss: Int)]) {
        var owner: [Int32: String] = [:], rows: [Int32: (cpu: Double, rss: Int)] = [:]
        for ls in sessions.live.all where only == nil || ls.snapshot.worktreeId == only { for p in ls.pty.tree() { owner[p] = ls.snapshot.id } }
        guard !owner.isEmpty else { return ([:], [:]) }
        for line in (Self.run(["/bin/ps", "-axo", "pid=,pcpu=,rss="], path: "/bin:/usr/bin", timeout: 3) ?? "").split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ")
            guard f.count == 3, let pid = Int32(f[0]) else { continue }
            rows[pid] = (Double(f[1]) ?? 0, (Int(f[2]) ?? 0) * 1024)
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
