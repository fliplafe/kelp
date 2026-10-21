import Foundation
import Core

// kelp: every action in the UI is available here, so agents can drive the app too.
let usage = """
usage: kelp <command>
  status                               repos, worktrees and sessions at a glance
  repo add [path] | repo list
  worktree create <branch> [--repo id] [--base b] | list | current | note <text> | remove <id> [--force] [--drop-commits] | archive <id>
  agent list                           (use `kelp session new --agent <id>`)
  session new [--agent id] [--worktree id] [--cmd "..."] [--split right|down] [--wait] | list
                                       --split opens its tab beside yours; --wait prints its id, then exits with
                                       its command's exit code when it ends
  wait <session> [--for done,waiting,idle,exited] [--timeout 10m]   until it stops working (or reaches one of those)
  terminal list | read <session> [bytes] | send <session> <text> [--no-enter]
  diff [--source unstaged|staged|all|branch] | commit <msg> | merge | push
  comment add <file> <line[-line]> <text> | send <session>
  session restart|rename <id> [title]|handoff <id> [--agent a]
  terminal context <session>          bounded transcript (for pasting elsewhere)
  attach <session>                     make this terminal the session's terminal (detach: close it)
  hook <working|waiting|done>          (called by agent hooks inside a session)
  report <working|blocked|done|error|idle|clear> [message] [--progress 0-100] [--kind permission|question|auth]
                                       inside a session: what you're doing, on your row and tab
  install | uninstall                  launchd agent for the daemon
  github prs|issues [--filter mine|review] | checks [pr] | pr-create [--title t] [--draft] | pr-merge | issue <n> [--send]
  linear login <key> | tasks | start <ENG-123> [--send]
                                       issue / start: the brief is typed into the new agent, not sent (--send sends it)
  open <path[:line]|url> [--split right|down] [--focus]   open a tab in the app (relative paths are fine);
                                                --focus also brings Kelp forward and shows that workspace
  settings | settings get <key> | set <key> <json-or-text> | unset <key>
  ui state                             what the app shows: workspace, tabs, extensions, commands
  run <command-id> [json-args]         run an app command (ids from `kelp ui state`)
  ext list | new <id> [--name N] [--description D] | enable <id> | disable <id> | reload | path
"""

// Internal: the daemon starts agents through this so the PTY becomes their controlling terminal
// (posix_spawn can't do TIOCSCTTY). Without it no SIGWINCH reaches them and resizes are ignored.
func ctty() -> Never {
    _ = ioctl(0, TIOCSCTTY, 0)
    let rest = Array(CommandLine.arguments.dropFirst(2))
    let cargs = rest.map { strdup($0) } + [nil]
    execvp(rest[0], cargs)
    FileHandle.standardError.write(Data("kelp: \(rest[0]): \(String(cString: strerror(errno)))\n".utf8)); exit(127)
}

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

nonisolated(unsafe) var args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func has(_ n: String) -> Bool { if let i = args.firstIndex(of: n) { args.remove(at: i); return true }; return false }

func daemonBinary() -> String {
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return me.deletingLastPathComponent().appendingPathComponent("kelpd").path
}

func connect() throws -> RPCClient {
    if let c = try? RPCClient() { return c }
    // Start the daemon on demand.
    let p = Process(); p.executableURL = URL(fileURLWithPath: daemonBinary())
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run()
    for _ in 0..<50 { usleep(100_000); if let c = try? RPCClient() { return c } }
    throw RPCError.internalError("cannot reach the Kelp daemon at \(Paths.socket.path)")
}

func show(_ v: JSONValue) {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if case .string(let s) = v { print(s) } else if v != .null, let d = try? e.encode(v), let s = String(bytes: d, encoding: .utf8) { print(s) }
}

/// A CLI value: JSON when it parses (3, true, [1], "x"), else the text itself.
func jsonOrText(_ s: String) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))) ?? .string(s) }

/// The workspace the current directory is in; an agent's own one (KELP_SESSION) when several share the folder.
func currentWorktree(_ c: RPCClient) async throws -> JSONValue {
    guard let w = try await IDE.workspace(cwd: FileManager.default.currentDirectoryPath, call: { try await c.call($0, $1) }) else {
        throw RPCError.invalidParams("not inside a kelp worktree")   // throws: callers use try? to fall back
    }
    return w
}
func currentRepoID(_ c: RPCClient) async throws -> String {
    if let r = flag("--repo") { return r }
    let cwd = FileManager.default.currentDirectoryPath
    let repos = try await c.call("repo.list").array ?? []
    if let id = repos.first(where: { r in r["path"]?.string.map { IDE.inside(cwd, $0) } ?? false })?["id"]?.string { return id }
    if let id = (try? await currentWorktree(c))?["repoId"]?.string { return id }
    fail("no repo here; pass --repo <id> or run `kelp repo add`")
}

func plist() -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>dev.kelp.daemon</string>
      <key>ProgramArguments</key><array><string>\(daemonBinary())</string></array>
      <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
    </dict></plist>
    """
}

@main struct Main {
    static func main() async {
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "__ctty" { ctty() }
        signal(SIGPIPE, SIG_IGN)
        guard !args.isEmpty else { print(usage); return }
        let cmd = args.removeFirst()
        do {
            switch cmd {
            case "install":
                let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/dev.kelp.daemon.plist")
                try plist().write(to: u, atomically: true, encoding: .utf8)
                _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["load", u.path])
                print("installed \(u.path)")
            case "uninstall":
                let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/dev.kelp.daemon.plist")
                _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["unload", u.path])
                try? FileManager.default.removeItem(at: u)
            case "attach":
                guard let id = args.first else { fail("kelp attach <session>") }
                Attach.run(id)
            case "hook":   // inside an agent session: report status to the daemon
                guard let id = ProcessInfo.processInfo.environment["KELP_SESSION"], let ev = args.first else { fail("hook: needs KELP_SESSION and an event") }
                let c = try RPCClient(socket: ProcessInfo.processInfo.environment["KELP_SOCKET"] ?? Paths.socket.path)
                var p: [String: JSONValue] = ["id": .string(id), "event": .string(ev)]
                // Claude Code hooks pass a JSON payload on stdin (session id, transcript path).
                if isatty(0) == 0, let d = try? FileHandle.standardInput.readToEnd(), let v = try? JSONDecoder().decode(JSONValue.self, from: d) {
                    if let t = v["transcript_path"]?.string { p["transcript"] = .string(t) }
                    if let t = v["cwd"]?.string { p["cwd"] = .string(t) }   // where it works now: its own worktree, maybe
                    if let t = v["trigger"]?.string { p["trigger"] = .string(t) }   // PreCompact: manual (/compact) or auto
                    if let t = v["background_tasks"] { p["background_tasks"] = t }   // Stop: subagents still running
                    if v["notification_type"] != nil || v["message"] != nil {
                        p["notification"] = .obj(["notification_type": v["notification_type"] ?? .null, "message": v["message"] ?? .null])
                    }
                }
                _ = try await c.call("session.hook", .object(p))
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
        switch cmd {
        case "status", "repo", "worktree": try await projects(cmd, sub, c)
        case "session", "terminal", "wait", "report": try await sessions(cmd, sub, c)
        case "diff", "commit", "merge", "push", "comment": try await git(cmd, sub, c)
        case "github", "linear": try await forge(cmd, sub, c)
        case "settings", "ui", "run": try await settingsAndUI(cmd, sub, c)
        case "ext": try await ext(sub, c)
        case "open": try await open(sub, c)
        default: print(usage)
        }
    }

    /// `open <path|url> [--split right|down] [--focus]`: a tab in the app.
    static func open(_ sub: String?, _ c: RPCClient) async throws {
        let split = flag("--split")
        let focus = has("--focus") || sub == "--focus"
        guard let target = sub.flatMap({ $0 == "--focus" ? nil : $0 }) ?? args.first else { fail("open <path|url> [--split right|down] [--focus]") }
        let cwd = FileManager.default.currentDirectoryPath
        show(try await IDE.open(target, split: split, cwd: cwd, focus: focus, call: { try await c.call($0, $1) }))
    }

    /// `status`, `repo …`, `worktree …`.
    static func projects(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
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
            _ = try await c.call(WorktreeNote(id: try await currentWorktree(c)["id"]?.string ?? "", note: args.joined(separator: " ")))
        case ("worktree", "remove"), ("worktree", "archive"):
            let force = has("--force"), drop = has("--drop-commits")   // two separate losses, each asked for by name
            show(try await c.call("worktree.\(sub ?? "")", .obj(["id": .string(try await resolve(c, args.first ?? "", "worktree.list")),
                                                                   "force": .bool(force), "dropCommits": .bool(drop)])))
        default: print(usage)
        }
    }

    /// `session …`, `terminal …`, `wait`, `report`.
    static func sessions(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("session", "new"):
            let wait = has("--wait"), split = flag("--split")
            var p: [String: JSONValue] = [:]
            if let a = flag("--agent") { p["agent"] = .string(a) }
            if let m = flag("--cmd") { p["command"] = .string(m) }
            // A session outside every workspace would run where no tab or sidebar row shows it.
            if let w = flag("--worktree") { p["worktreeId"] = .string(try await resolve(c, w, "worktree.list")) }
            else if let w = try? await currentWorktree(c) { p["worktreeId"] = w["id"] }
            else { fail("not inside a Kelp project: run it in a project's folder or pass --worktree <id> (see `kelp status`)") }
            let s = try await c.call("session.create", .object(p))
            guard let id = s["id"]?.string else { show(s); return }
            // Its tab beside yours; without the app it runs all the same (its row shows once the app opens).
            if let split { _ = try? await IDE.open("session:\(id)", split: split, cwd: FileManager.default.currentDirectoryPath, call: { try await c.call($0, $1) }) }
            guard wait else { show(s); return }
            print(id)   // for `kelp terminal read`, once it ends
            exit(Int32(try await waitFor(c, id, timeout: nil) { $0.status == .exited }?.exitCode ?? 1))
        case ("session", "list"), ("terminal", "list"): show(try await c.call("session.list"))
        case ("wait", let target?):   // until the session stops working, or reaches one of --for; prints the state it reached
            let want = flag("--for").map { Set($0.split(separator: ",").map(String.init)) }, timeout = flag("--timeout").map(duration)
            let id = try await resolve(c, target, "session.list")
            guard let s = try await waitFor(c, id, timeout: timeout, until: { want?.contains($0.status.rawValue) ?? ($0.status != .working) }) else { fail("timed out") }
            print(s.status.rawValue)
            if s.status == .exited { exit(Int32(s.exitCode ?? 0)) }   // its command's exit code
        case ("report", let state?):   // inside a session: what this program is doing, on its row and tab
            guard let id = ProcessInfo.processInfo.environment["KELP_SESSION"] else { fail("report: run it inside a Kelp session") }
            let progress = flag("--progress").flatMap { Int($0) }, kind = flag("--kind"), msg = args.joined(separator: " ")
            _ = try await c.call(SessionReport(id: id, state: state, message: msg.isEmpty ? nil : msg, progress: progress, kind: kind))
        case ("terminal", "read"):
            show(try await c.call("session.read", .obj(["id": .string(try await resolve(c, args.first ?? "", "session.list")), "bytes": .int(args.dropFirst().first.flatMap(Int.init) ?? 8192)])))
        case ("terminal", "send"):
            let enter = !has("--no-enter")
            guard args.count >= 2 else { fail("terminal send <session> <text>") }
            let id = try await resolve(c, args[0], "session.list")
            show(try await c.call("session.send", .obj(["id": .string(id), "text": .string(args.dropFirst().joined(separator: " ")), "enter": .bool(enter)])))
        case ("session", "restart"):
            show(try await c.call("session.restart", .obj(["id": .string(try await resolve(c, args.first ?? "", "session.list"))])))
        case ("session", "rename"):
            _ = try await c.call(SessionRename(id: try await resolve(c, args.first ?? "", "session.list"), title: args.dropFirst().joined(separator: " ")))
        case ("session", "handoff"):
            var p: [String: JSONValue] = ["id": .string(try await resolve(c, args.first ?? "", "session.list"))]
            if let a = flag("--agent") { p["agent"] = .string(a) }
            show(try await c.call("session.handoff", .object(p)))
        case ("terminal", "context"):
            show(try await c.call("session.context", .obj(["id": .string(try await resolve(c, args.first ?? "", "session.list"))])))
        default: print(usage)
        }
    }

    /// `diff`, `commit`, `merge`, `push`, `comment …` in the current workspace.
    static func git(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("diff", _):
            let w = try await currentWorktree(c)
            let d = try await c.call("git.diff", .obj(["id": w["id"] ?? .null, "source": .string(flag("--source") ?? "all")]))
            for f in d.array ?? [] {
                let lines = (f["hunks"]?.array ?? []).flatMap { $0["lines"]?.array ?? [] }
                func count(_ kind: String) -> Int { lines.filter { $0["kind"]?.string == kind }.count }
                print("\(f["path"]?.string ?? "")  +\(count("add")) -\(count("del"))")
            }
        case ("commit", _):
            show(try await c.call("git.commit", .obj(["id": try await currentWorktree(c)["id"] ?? .null, "message": .string(([sub].compactMap { $0 } + args).joined(separator: " ")), "all": true])))
        case ("merge", _): show(try await c.call("git.merge", .obj(["id": try await currentWorktree(c)["id"] ?? .null])))
        case ("push", _): show(try await c.call("git.push", .obj(["id": try await currentWorktree(c)["id"] ?? .null])))
        case ("comment", "add"):
            guard args.count >= 3 else { fail("comment add <file> <line[-line]> <text>") }
            let range = args[1].split(separator: "-").compactMap { Int($0) }
            let id = try await currentWorktree(c)["id"] ?? .null, text = args.dropFirst(2).joined(separator: " ")
            show(try await c.call("comment.add", .obj(["id": id, "file": .string(args[0]), "start": .int(range.first ?? 1), "end": .int(range.last ?? 1), "text": .string(text)])))
        case ("comment", "send"):
            show(try await c.call("comment.send", .obj(["id": try await currentWorktree(c)["id"] ?? .null, "session": .string(try await resolve(c, args.first ?? "", "session.list"))])))
        default: print(usage)
        }
    }

    /// `github …`, `linear …`.
    static func forge(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("github", "prs"), ("github", "issues"):
            var p: [String: JSONValue] = ["repoId": .string(try await currentRepoID(c))]
            if let f = flag("--filter") { p["filter"] = .string(f) }
            for x in try await c.call("github.\(sub ?? "")", .object(p)).array ?? [] {
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
        case ("github", "issue"), ("linear", "start"):   // kelp github issue 123 | kelp linear start ENG-123
            let repo = try await currentRepoID(c)
            guard let ref = args.first else { fail("issue number / identifier required") }
            var p: [String: JSONValue] = ["repoId": .string(repo), "agent": .string(flag("--agent") ?? "claude")]
            if cmd == "github" {
                let n = Int(ref.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) ?? 0
                let open = try await c.call("github.issues", .obj(["repoId": .string(repo)])).array ?? []
                guard let i = open.first(where: { $0["number"]?.int == n }) else { fail("issue #\(n) not found among open issues") }
                p["ref"] = .string("#\(n)"); p["title"] = i["title"] ?? ""; p["body"] = i["body"] ?? ""; p["url"] = i["url"] ?? ""
            } else {
                let mine = try await c.call("linear.issues").array ?? []
                guard let i = mine.first(where: { $0["identifier"]?.string?.lowercased() == ref.lowercased() }) else { fail("\(ref) not found in your Linear issues") }
                p["ref"] = i["identifier"] ?? ""; p["title"] = i["title"] ?? ""; p["body"] = i["description"] ?? ""; p["url"] = i["url"] ?? ""; p["linearId"] = i["id"] ?? ""
            }
            if has("--send") { p["draft"] = false }
            let r = try await c.call("task.fromIssue", .object(p))
            print("\(r["worktree"]?["branch"]?.string ?? "")  \(r["worktree"]?["path"]?.string ?? "")")
            if !has("--send") { print("The issue's text is typed into the agent, not sent: look it over in Kelp and press Return.") }
            if r["setupNeedsTrust"]?.bool == true { print("Its .kelp.yaml setup didn't run: open the project in Kelp to look at it and trust it.") }
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

    static func settingsAndUI(_ cmd: String, _ sub: String?, _ c: RPCClient) async throws {
        switch (cmd, sub) {
        case ("settings", nil): show(try await c.call("settings.get"))
        case ("settings", "get"):
            guard let k = args.first else { fail("settings get <key>") }
            show(try await c.call("settings.get")[k] ?? .null)
        case ("settings", "set"):
            guard args.count >= 2 else { fail("settings set <key> <value>") }
            _ = try await c.call("settings.set", .obj(["key": .string(args[0]), "value": jsonOrText(args.dropFirst().joined(separator: " "))]))
        case ("settings", "unset"):
            guard let k = args.first else { fail("settings unset <key>") }
            _ = try await c.call("settings.set", .obj(["key": .string(k)]))
        case ("ui", "state"): show(try await c.call("ui.state"))
        case ("run", let id?):
            var p: [String: JSONValue] = ["id": .string(id)]
            if !args.isEmpty { p["args"] = jsonOrText(args.joined(separator: " ")) }
            show(try await c.call("ui.command", .object(p)))
        default: print(usage)
        }
    }

    static func ext(_ sub: String?, _ c: RPCClient) async throws {
        let call: IDE.Call = { try await c.call($0, $1) }
        switch sub {
        case "list":
            for e in try await IDE.extensions(call: call).array ?? [] {
                let tags = [e["builtin"]?.bool == true ? "(built-in)" : nil, e["enabled"]?.bool == false ? "(disabled)" : nil].compactMap { $0 }
                print(([e["id"]?.string ?? "", e["name"]?.string ?? ""] + tags).joined(separator: "\t"))
            }
        case "new":
            let name = flag("--name"), description = flag("--description")
            guard let id = args.first else { fail("ext new <id> [--name N] [--description D]") }
            let folder = try IDE.scaffoldExtension(id: id, name: name, description: description)
            print("created \(folder.path)\nguide:   \(folder.deletingLastPathComponent().appendingPathComponent("EXTENSIONS.md").path)")
        case "enable", "disable":
            guard let id = args.first else { fail("ext enable|disable <id>") }
            try await IDE.setExtension(id, enabled: sub == "enable", call: call)
        case "reload": show(try await c.call("ui.command", .obj(["id": "extensions.reload"])))
        case "path": print(Paths.extensions.path)
        default: print(usage)
        }
    }

    /// Accept a full id or a unique prefix (what `kelp status` prints).
    /// Looks at the session twice a second until `done` says so, or it ended or was paused (it can't change then);
    /// nil when `timeout` ran out first.
    static func waitFor(_ c: RPCClient, _ id: String, timeout: TimeInterval?, until done: (Session) -> Bool) async throws -> Session? {
        let end = timeout.map { Date().addingTimeInterval($0) }
        while true {
            guard let s = try await c.call("session.list", as: [Session].self).first(where: { $0.id == id }) else { fail("no session \(id)") }
            if done(s) || s.status == .exited || s.status == .hibernated { return s }
            if let end, Date() > end { return nil }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// "90", "30s", "10m", "1h" → seconds.
    static func duration(_ s: String) -> TimeInterval {
        let unit = ["s": 1.0, "m": 60, "h": 3600][String(s.suffix(1))]
        guard let n = Double(unit == nil ? s : String(s.dropLast())) else { fail("bad duration \(s): use 30s, 10m or 1h") }
        return n * (unit ?? 1)
    }

    static func resolve(_ c: RPCClient, _ prefix: String, _ listMethod: String) async throws -> String {
        guard !prefix.isEmpty else { fail("id required") }
        let found = ((try await c.call(listMethod).array) ?? []).compactMap { $0["id"]?.string }.filter { $0.hasPrefix(prefix) }
        guard found.count == 1 else { fail(found.isEmpty ? "no match for \(prefix)" : "ambiguous: \(prefix)") }
        return found[0]
    }
}
