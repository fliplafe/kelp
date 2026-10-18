import Foundation
import Core

// krill: every action in the UI is available here, so agents can drive the app too.
let usage = """
usage: krill <command>
  status                               repos, worktrees and sessions at a glance
  repo add [path] | repo list
  worktree create <branch> [--repo id] [--base b] | list | current | note <text> | remove <id> [--force] | archive <id>
  agent list                           (use `krill session new --agent <id>`)
  session new [--agent id] [--worktree id] [--cmd "..."] | list
  terminal list | read <session> [bytes] | send <session> <text> [--no-enter]
  diff [--source unstaged|staged|all|branch] | commit <msg> | merge | push
  comment add <file> <line[-line]> <text> | send <session>
  task <prompt> [--agent id] [--model m] [--yolo]   new branch (named on-device) + worktree + agent
  session restart|rename <id> [title]|handoff <id> [--agent a]|fork <id>
  terminal context <session>          bounded transcript (for pasting elsewhere)
  fanout <prompt> --agents claude,codex [--repo id]
  hook <working|waiting|done>          (called by agent hooks inside a session)
  install | uninstall                  launchd agent for the daemon
  github prs|issues [--filter mine|review] | checks [pr] | pr-create [--title t] [--draft] | pr-merge | issue <n>
  linear login <key> | tasks | start <ENG-123>
"""

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

nonisolated(unsafe) var args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func has(_ n: String) -> Bool { if let i = args.firstIndex(of: n) { args.remove(at: i); return true }; return false }

func daemonBinary() -> String {
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return me.deletingLastPathComponent().appendingPathComponent("krilld").path
}

func connect() throws -> RPCClient {
    if let c = try? RPCClient() { return c }
    // Start the daemon on demand.
    let p = Process(); p.executableURL = URL(fileURLWithPath: daemonBinary())
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run()
    for _ in 0..<50 { usleep(100_000); if let c = try? RPCClient() { return c } }
    fail("cannot reach daemon at \(Paths.socket.path)")
}

func show(_ v: JSONValue) {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if case .string(let s) = v { print(s) } else if v != .null, let d = try? e.encode(v) { print(String(decoding: d, as: UTF8.self)) }
}

func inside(_ cwd: String, _ path: String) -> Bool {
    let r = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
    let (c, p) = (r(cwd), r(path))
    return c == p || c.hasPrefix(p + "/")
}

/// Worktree whose path contains the current directory.
func currentWorktree(_ c: RPCClient) async throws -> JSONValue {
    let cwd = FileManager.default.currentDirectoryPath
    let all = try await c.call("worktree.list").array ?? []
    guard let w = all.first(where: { w in w["path"]?.string.map { inside(cwd, $0) } ?? false }) else { fail("not inside a krill worktree") }
    return w
}
func currentRepoID(_ c: RPCClient) async throws -> String {
    if let r = flag("--repo") { return r }
    let cwd = FileManager.default.currentDirectoryPath
    let repos = try await c.call("repo.list").array ?? []
    if let r = repos.first(where: { r in r["path"]?.string.map { inside(cwd, $0) } ?? false }) { return r["id"]!.string! }
    if let w = try? await currentWorktree(c) { return w["repoId"]!.string! }
    fail("no repo here; pass --repo <id> or run `krill repo add`")
}

func plist() -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>dev.krill.daemon</string>
      <key>ProgramArguments</key><array><string>\(daemonBinary())</string></array>
      <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
    </dict></plist>
    """
}

@main struct Main {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        guard !args.isEmpty else { print(usage); return }
        let cmd = args.removeFirst()
        do {
            switch cmd {
            case "install":
                let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/dev.krill.daemon.plist")
                try plist().write(to: u, atomically: true, encoding: .utf8)
                _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["load", u.path])
                print("installed \(u.path)")
            case "uninstall":
                let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/dev.krill.daemon.plist")
                _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["unload", u.path])
                try? FileManager.default.removeItem(at: u)
            case "hook":   // inside an agent session: report status to the daemon
                guard let id = ProcessInfo.processInfo.environment["KRILL_SESSION"], let ev = args.first else { fail("hook: needs KRILL_SESSION and an event") }
                let c = try RPCClient(socket: ProcessInfo.processInfo.environment["KRILL_SOCKET"] ?? Paths.socket.path)
                _ = try await c.call("session.hook", .obj(["id": .string(id), "event": .string(ev)]))
            default:
                let c = try connect()
                try await run(cmd, c)
            }
        } catch let e as RPCError { fail("error: \(e.message)") }
        catch { fail("error: \(error)") }
    }

    static func run(_ cmd: String, _ c: RPCClient) async throws {
        let sub = args.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        if sub != nil { args.removeFirst() }
        switch (cmd, sub) {
        case ("status", _):
            let repos = try await c.call("repo.list").array ?? []
            let wts = try await c.call("worktree.list").array ?? []
            let ss = try await c.call("session.list").array ?? []
            for r in repos {
                print("\(r["name"]?.string ?? "?")  \(r["path"]?.string ?? "")")
                for w in wts where w["repoId"] == r["id"] {
                    let note = (w["note"]?.string).flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
                    print("  \(w["branch"]?.string ?? "?")  [\(w["id"]?.string?.prefix(8) ?? "")]\(note)")
                    for s in ss where s["worktreeId"] == w["id"] {
                        print("    \(s["agent"]?.string ?? "cmd") \(s["status"]?.string ?? "")\(s["unread"]?.bool == true ? " •" : "")  [\(s["id"]?.string?.prefix(8) ?? "")]")
                    }
                }
            }
        case ("repo", "add"): show(try await c.call("repo.add", .obj(["path": .string(args.first ?? FileManager.default.currentDirectoryPath)])))
        case ("repo", "list"): show(try await c.call("repo.list"))
        case ("worktree", "create"):
            guard let b = args.first, !b.hasPrefix("-") else { fail("worktree create <branch>") }
            args.removeFirst()
            var p: [String: JSONValue] = ["branch": .string(b), "repoId": .string(try await currentRepoID(c))]
            if let base = flag("--base") { p["base"] = .string(base) }
            if has("--no-setup") { p["setup"] = false }
            show(try await c.call("worktree.create", .object(p)))
        case ("worktree", "list"): show(try await c.call("worktree.list", has("--all") ? .obj(["archived": true]) : nil))
        case ("worktree", "current"): show(try await currentWorktree(c))
        case ("worktree", "note"):
            show(try await c.call("worktree.note", .obj(["id": try await currentWorktree(c)["id"] ?? .null, "note": .string(args.joined(separator: " "))])))
        case ("worktree", "remove"), ("worktree", "archive"):
            let force = has("--force")
            show(try await c.call("worktree.\(sub!)", .obj(["id": .string(try await resolve(c, args.first ?? "", "worktree.list")), "force": .bool(force)])))
        case ("session", "new"):
            var p: [String: JSONValue] = [:]
            if let a = flag("--agent") { p["agent"] = .string(a) }
            if let m = flag("--cmd") { p["command"] = .string(m) }
            if let w = flag("--worktree") { p["worktreeId"] = .string(try await resolve(c, w, "worktree.list")) }
            else if p["cwd"] == nil { if let w = try? await currentWorktree(c) { p["worktreeId"] = w["id"] } else { p["cwd"] = .string(FileManager.default.currentDirectoryPath) } }
            show(try await c.call("session.create", .object(p)))
        case ("session", "list"), ("terminal", "list"): show(try await c.call("session.list"))
        case ("terminal", "read"):
            show(try await c.call("session.read", .obj(["id": .string(try await resolve(c, args.first ?? "", "session.list")), "bytes": .int(args.dropFirst().first.flatMap(Int.init) ?? 8192)])))
        case ("terminal", "send"):
            let enter = !has("--no-enter")
            guard args.count >= 2 else { fail("terminal send <session> <text>") }
            show(try await c.call("session.send", .obj(["id": .string(try await resolve(c, args[0], "session.list")), "text": .string(args.dropFirst().joined(separator: " ")), "enter": .bool(enter)])))
        case ("diff", _):
            let w = try await currentWorktree(c)
            let d = try await c.call("git.diff", .obj(["id": w["id"] ?? .null, "source": .string(flag("--source") ?? "all")]))
            for f in d.array ?? [] { print("\(f["path"]?.string ?? "")  +\((f["hunks"]?.array ?? []).flatMap { $0["lines"]?.array ?? [] }.filter { $0["kind"]?.string == "add" }.count) -\((f["hunks"]?.array ?? []).flatMap { $0["lines"]?.array ?? [] }.filter { $0["kind"]?.string == "del" }.count)") }
        case ("commit", _):
            show(try await c.call("git.commit", .obj(["id": try await currentWorktree(c)["id"] ?? .null, "message": .string(([sub].compactMap { $0 } + args).joined(separator: " ")), "all": true])))
        case ("merge", _): show(try await c.call("git.merge", .obj(["id": try await currentWorktree(c)["id"] ?? .null])))
        case ("push", _): show(try await c.call("git.push", .obj(["id": try await currentWorktree(c)["id"] ?? .null])))
        case ("comment", "add"):
            guard args.count >= 3 else { fail("comment add <file> <line[-line]> <text>") }
            let range = args[1].split(separator: "-").compactMap { Int($0) }
            show(try await c.call("comment.add", .obj(["id": try await currentWorktree(c)["id"] ?? .null, "file": .string(args[0]), "start": .int(range.first ?? 1), "end": .int(range.last ?? 1), "text": .string(args.dropFirst(2).joined(separator: " "))])))
        case ("comment", "send"):
            show(try await c.call("comment.send", .obj(["id": try await currentWorktree(c)["id"] ?? .null, "session": .string(try await resolve(c, args.first ?? "", "session.list"))])))
        case ("task", _):
            var p: [String: JSONValue] = ["repoId": .string(try await currentRepoID(c))]
            if let a = flag("--agent") { p["agent"] = .string(a) }
            if let m = flag("--model") { p["model"] = .string(m) }
            if has("--yolo") { p["mode"] = "yolo" }
            p["prompt"] = .string(([sub].compactMap { $0 } + args).joined(separator: " "))
            let r = try await c.call("task.create", .object(p))
            print("\(r["worktree"]?["branch"]?.string ?? "")  \(r["worktree"]?["path"]?.string ?? "")  session \(r["session"]?["id"]?.string?.prefix(8) ?? "")")
        case ("session", "restart"), ("session", "fork"):
            show(try await c.call("session.\(sub!)", .obj(["id": .string(try await resolve(c, args.first ?? "", "session.list"))])))
        case ("session", "rename"):
            show(try await c.call("session.rename", .obj(["id": .string(try await resolve(c, args.first ?? "", "session.list")), "title": .string(args.dropFirst().joined(separator: " "))])))
        case ("session", "handoff"):
            var p: [String: JSONValue] = ["id": .string(try await resolve(c, args.first ?? "", "session.list"))]
            if let a = flag("--agent") { p["agent"] = .string(a) }
            show(try await c.call("session.handoff", .object(p)))
        case ("terminal", "context"):
            show(try await c.call("session.context", .obj(["id": .string(try await resolve(c, args.first ?? "", "session.list"))])))
        case ("fanout", _):
            let agents = (flag("--agents") ?? "claude").split(separator: ",").map { JSONValue.string(String($0)) }
            let repo = try await currentRepoID(c)
            show(try await c.call("fanout.start", .obj(["repoId": .string(repo), "prompt": .string(([sub].compactMap { $0 } + args).joined(separator: " ")), "agents": .array(agents)])))
        case ("github", "prs"), ("github", "issues"):
            var p: [String: JSONValue] = ["repoId": .string(try await currentRepoID(c))]
            if let f = flag("--filter") { p["filter"] = .string(f) }
            for x in try await c.call("github.\(sub!)", .object(p)).array ?? [] {
                print("#\(x["number"]?.int ?? 0)  \(x["title"]?.string ?? "")  \(x["url"]?.string ?? "")")
            }
        case ("github", "checks"):
            let w = try await currentWorktree(c)
            let pr = args.first.flatMap(Int.init) ?? w["prNumber"]?.int ?? 0
            for x in try await c.call("github.checks", .obj(["worktreeId": w["id"] ?? .null, "pr": .int(pr)])).array ?? [] {
                print("\(x["bucket"]?.string ?? "")\t\(x["name"]?.string ?? "")\t\(x["link"]?.string ?? "")")
            }
        case ("github", "pr-create"):
            let w = try await currentWorktree(c)
            var p: [String: JSONValue] = ["worktreeId": w["id"] ?? .null]
            if let t = flag("--title") { p["title"] = .string(t) }
            if has("--draft") { p["draft"] = true }
            show(try await c.call("github.pr-create", .object(p))["url"] ?? .null)
        case ("github", "pr-merge"):
            show(try await c.call("github.pr-merge", .obj(["worktreeId": try await currentWorktree(c)["id"] ?? .null, "method": .string(flag("--method") ?? "squash")])))
        case ("github", "issue"), ("linear", "start"):   // krill github issue 123 | krill linear start ENG-123
            let repo = try await currentRepoID(c)
            guard let ref = args.first else { fail("issue number / identifier required") }
            var p: [String: JSONValue] = ["repoId": .string(repo), "agent": .string(flag("--agent") ?? "claude")]
            if cmd == "github" {
                let n = Int(ref.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) ?? 0
                guard let i = (try await c.call("github.issues", .obj(["repoId": .string(repo)])).array ?? []).first(where: { $0["number"]?.int == n }) else { fail("issue #\(n) not found among open issues") }
                p["ref"] = .string("#\(n)"); p["title"] = i["title"] ?? ""; p["body"] = i["body"] ?? ""; p["url"] = i["url"] ?? ""
            } else {
                guard let i = (try await c.call("linear.issues").array ?? []).first(where: { $0["identifier"]?.string?.lowercased() == ref.lowercased() }) else { fail("\(ref) not found in your Linear issues") }
                p["ref"] = i["identifier"] ?? ""; p["title"] = i["title"] ?? ""; p["body"] = i["description"] ?? ""; p["url"] = i["url"] ?? ""; p["linearId"] = i["id"] ?? ""
            }
            let r = try await c.call("task.fromIssue", .object(p))
            print("\(r["worktree"]?["branch"]?.string ?? "")  \(r["worktree"]?["path"]?.string ?? "")")
        case ("linear", "tasks"):
            for x in try await c.call("linear.issues").array ?? [] {
                print("\(x["identifier"]?.string ?? "")  [\(x["state"]?["name"]?.string ?? "")]  \(x["title"]?.string ?? "")")
            }
        case ("linear", "login"):
            guard let k = args.first else { fail("linear login <api-key>") }
            show(try await c.call("linear.setKey", .obj(["key": .string(k)])))
        default: print(usage)
        }
    }

    /// Accept a full id or a unique prefix (what `krill status` prints).
    static func resolve(_ c: RPCClient, _ prefix: String, _ listMethod: String) async throws -> String {
        guard !prefix.isEmpty else { fail("id required") }
        let found = ((try await c.call(listMethod).array) ?? []).compactMap { $0["id"]?.string }.filter { $0.hasPrefix(prefix) }
        guard found.count == 1 else { fail(found.isEmpty ? "no match for \(prefix)" : "ambiguous: \(prefix)") }
        return found[0]
    }
}
