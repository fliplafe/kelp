import Foundation
import Core
import GitKit

/// Source Control panel: branches, history graph, discard, pull / push / fetch, stash. Everything runs here, off the UI.
extension Daemon {
    func handleGit(_ method: String, _ p: JSONValue) throws -> JSONValue? {
        switch method {
        case "git.branches": return try .from(Git.branches(cwd(forWorktree: p.req("id")).path))
        case "git.switch":   // {id, branch, create?, remote?}
            try Git.switchBranch(cwd(forWorktree: p.req("id")).path, to: p.req("branch"),
                                 create: p["create"]?.bool == true, remote: p["remote"]?.bool == true)
            return .null
        case "git.graph":    // {id, limit?} → {commits, more}
            let g = try Git.graph(cwd(forWorktree: p.req("id")).path, limit: max(1, p["limit"]?.int ?? 200))
            return .obj(["commits": try .from(g.commits), "more": .bool(g.more)])
        case "git.commitFiles": return try .from(Git.commitFiles(cwd(forWorktree: p.req("id")).path, commit: p.req("commit")))
        case "git.discard":
            try Git.discard(cwd(forWorktree: p.req("id")).path, files: (p["files"]?.array ?? []).compactMap(\.string))
            return .null
        case "git.remote":   // {id, op: pull | push | fetch}
            guard let op = Git.Remote(rawValue: try p.req("op")) else { throw RPCError.invalidParams("op: pull, push or fetch") }
            try Git.remote(cwd(forWorktree: p.req("id")).path, op)
            return .null
        case "git.stash": try Git.stash(cwd(forWorktree: p.req("id")).path, pop: p["pop"]?.bool == true); return .null
        case "git.lineStats": return try .from(Git.lineStats(cwd(forWorktree: p.req("id")).path))
        case "git.webURL":   // {path, start?, end?} → the file on GitHub / GitLab / Bitbucket at HEAD
            let start = p["start"]?.int, end = p["end"]?.int ?? p["start"]?.int
            return .string(try Git.webURL(path: p.req("path"), lines: start.flatMap { s in end.map { min(s, $0)...max(s, $0) } }))
        default: return nil
        }
    }
}
