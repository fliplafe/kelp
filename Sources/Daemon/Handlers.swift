import Foundation
import Core
import GitKit
import Agents

extension JSONValue {
    func req(_ k: String) throws -> String {
        guard let s = self[k]?.string else { throw RPCError.invalidParams("missing \(k)") }
        return s
    }
}

extension Daemon {
    func handle(_ method: String, _ p: JSONValue, conn: Int) async throws -> JSONValue {
        if let e = extra[method] { return try await e(self, p) }
        do {
            if let r = try await handleAsync(method, p, conn: conn) { return r }
            if method.hasPrefix("usage.") || method.hasPrefix("history."), let r = try await handleHistory(method, p) { return r }
            if ["github.", "linear.", "jira.", "bitbucket."].contains(where: method.hasPrefix) || method == "task.fromIssue",
               let r = try await handleIntegration(method, p, conn: conn) { return r }
        }
        catch let e as GitError { throw RPCError.internalError(e.description) }
        do { return try handleSync(method, p, conn: conn) }
        catch let e as GitError { throw RPCError.internalError(e.description) }
    }

    private func handleSync(_ method: String, _ p: JSONValue, conn: Int) throws -> JSONValue {
        if method.hasPrefix("chat."), let r = try handleChat(method, p) { return r }
        if let r = try handleSettings(method, p) ?? handleUI(method, p, conn: conn) { return r }
        switch method {
        case "ping": return "pong"
        case "daemon.info":   // the app compares this with the krilld it ships to detect updates
            let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let liveCount = lock.withLock { live.values.filter { $0.snapshot.status != .exited }.count }
            return .obj(["path": .string(exe.resolvingSymlinksInPath().path), "binaryMTime": .double(Self.binaryMTime), "pid": .int(Int(getpid())),
                         "liveSessions": .int(liveCount)])
        case "daemon.shutdown":
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.stop(); exit(0) }
            return .null

        // MARK: repos
        case "repo.add":
            let root = try Git.root(of: p.req("path"))
            if let r = try store.repos().first(where: { $0.path == root }) { return try .from(r) }
            let r = Repo(name: p["name"]?.string ?? (root as NSString).lastPathComponent, path: root, baseBranch: Git.defaultBranch(repo: root))
            try store.save(r); try syncMainWorkspaces(); notify("event.changed", "repo")
            return try .from(r)
        case "repo.list": return try .from(store.repos())
        case "repo.branches":   // local branches, for "based on" pickers (stacked work)
            guard let r = try store.repo(p.req("id")) else { throw RPCError.invalidParams("no repo") }
            return .array(try Git.run(["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads"], cwd: r.path)
                .split(separator: "\n").map { .string(String($0)) })
        case "repo.remove":
            guard let r = try store.repo(p.req("id")) else { throw RPCError.invalidParams("no repo") }
            try store.delete(r); notify("event.changed", "repo"); return .null

        // MARK: worktrees
        case "worktree.create":
            guard let r = try store.repo(p.req("repoId")) else { throw RPCError.invalidParams("no repo") }
            let auto = try nextWorkspace(in: r)
            let branch = p["branch"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? auto.branch
            let base = p["base"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? r.baseBranch
            let path = try Git.addWorktree(repo: r.path, branch: branch, base: base,
                                           into: root.appendingPathComponent("worktrees/\(r.name)"), copyFiles: r.copyFiles)
            let w = Worktree(repoId: r.id, branch: branch, path: path, note: p["note"]?.string ?? (p["branch"] == nil ? auto.name : ""), base: base)
            try store.save(w)
            var result = try JSONValue.from(w)
            let cfg = RepoConfig.load(repoPath: r.path)
            Git.linkShared(cfg.shared, repo: r.path, worktree: path)
            if p["tabs"]?.bool != false { for t in cfg.tabs { _ = try? spawn(cwd: path, manifest: manifest(t, command: nil), worktreeId: w.id) } }
            if let setup = cfg.setup, p["setup"]?.bool != false {
                var o = Launch(); o.title = "setup"
                let s = try spawn(cwd: path, manifest: .custom(setup), worktreeId: w.id, o)
                if case .object(var o) = result { o["setupSession"] = .string(s.id); result = .object(o) }
            }
            notify("event.changed", "worktree")
            return result
        case "worktree.list":
            try syncMainWorkspaces()
            return try .from(store.worktrees(repo: p["repoId"]?.string).filter { p["archived"]?.bool == true || !$0.archived })
        case "worktree.note":
            guard var w = try store.worktree(p.req("id")) else { throw RPCError.invalidParams("no worktree") }
            w.note = try p.req("note"); try store.save(w); notify("event.changed", "worktree"); return .null
        case "worktree.run", "worktree.test":
            let w = try cwd(forWorktree: p.req("id"))
            guard let r = try store.repo(w.repoId) else { throw RPCError.invalidParams("no repo") }
            let cfg = RepoConfig.load(repoPath: r.path)
            guard let cmd = method == "worktree.run" ? cfg.run : cfg.test else { throw RPCError.invalidParams("no \(method.dropFirst(9)) script in .krill.yaml") }
            if method == "worktree.run" {
                var o = Launch(); o.title = "dev server"
                let s = try spawn(cwd: w.path, manifest: .custom(cmd), worktreeId: w.id, o)
                let wid = w.id
                try liveSession(s.id).onLocalURL = { [weak self] url in self?.notify("event.devserver", .obj(["worktree": .string(wid), "url": .string(url), "session": .string(s.id)])) }
                return try .from(s)
            }
            let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/bin/zsh"); pr.arguments = ["-lc", cmd]
            pr.currentDirectoryURL = URL(fileURLWithPath: w.path)
            pr.standardOutput = FileHandle.nullDevice; pr.standardError = FileHandle.nullDevice
            try pr.run(); pr.waitUntilExit()
            return .obj(["exit": .int(Int(pr.terminationStatus)), "passed": .bool(pr.terminationStatus == 0)])
        case "worktree.archive", "worktree.remove":
            guard var w = try store.worktree(p.req("id")), let r = try store.repo(w.repoId) else { throw RPCError.invalidParams("no worktree") }
            if isMain(w, r) { throw RPCError.invalidParams("The main workspace is the repository itself; remove the project instead.") }
            let remove = method == "worktree.remove"
            if FileManager.default.fileExists(atPath: w.path) {
                try Git.removeWorktree(repo: r.path, path: w.path, branch: remove ? w.branch : nil, force: p["force"]?.bool == true)
            }
            for s in (try store.sessions()) where s.worktreeId == w.id { existing(s.id)?.pty.kill() }
            if remove { try store.delete(w) } else { w.archived = true; try store.save(w) }
            notify("event.changed", "worktree"); return .null
        case "worktree.dirty":
            return .bool(try Git.isDirty(cwd(forWorktree: p.req("id")).path))

        // MARK: sessions
        case "session.create":
            // cwd wins when both are given (e.g. an agent building an extension, shown in the current workspace).
            var dir = p["cwd"]?.string.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }; let wid = p["worktreeId"]?.string
            if let wid, dir == nil { dir = try cwd(forWorktree: wid).path }
            guard let dir else { throw RPCError.invalidParams("cwd or worktreeId required") }
            let m = try manifest(p["agent"]?.string, command: p["command"]?.string)
            let s = try spawn(cwd: dir, manifest: m, worktreeId: wid, Launch(p))
            if p["openURLs"]?.bool == true, let wid {   // e.g. Jupyter Lab: its URL opens in the worktree's browser
                existing(s.id)?.onLocalURL = { [weak self] url in self?.notify("event.devserver", .obj(["worktree": .string(wid), "url": .string(url), "session": .string(s.id)])) }
            }
            return try .from(s)
        case "session.list":
            let live = try store.sessions().map { s -> Session in existing(s.id)?.snapshot ?? s }
            return try .from(live.filter { p["worktreeId"]?.string == nil || $0.worktreeId == p["worktreeId"]?.string })
        case "session.attach":
            let s = try liveSession(p.req("id"))
            let hist = s.attach(conn)
            if let r = s.markRead() { try store.save(r); notify("event.session", try .from(r)) }
            return .obj(["history": .string(hist.base64EncodedString())])
        case "session.detach": existing(try p.req("id"))?.detach(conn); return .null
        case "session.write":
            let s = try liveSession(p.req("id"))
            if let b = p["base64"]?.string, let d = Data(base64Encoded: b) { s.userInput(d) }
            else { s.pty.write(Data(try p.req("text").utf8)) }
            return .null
        case "session.send":   // text, then Enter after a beat so TUIs treat it as a submit, not a paste
            try liveSession(p.req("id")).send(p.req("text"), enter: p["enter"]?.bool != false)
            return .null
        case "session.resize": try liveSession(p.req("id")).resize(cols: UInt16(p["cols"]?.int ?? 120), rows: UInt16(p["rows"]?.int ?? 32)); return .null
        case "session.kill":
            if let ls = lock.withLock({ live[(p["id"]?.string ?? "")] }) { ls.pty.kill() }
            else if var s = try store.session(p.req("id")), s.status == .hibernated { s.status = .exited; publish(s) }   // don't wake just to kill
            return .null
        case "session.read":
            let d = try liveSessionOrLog(p.req("id"), bytes: p["bytes"]?.int ?? 8192)
            // swiftlint:disable:next optional_data_string_conversion
            return .string(StatusDetector.stripANSI(String(decoding: d, as: UTF8.self)))   // lossy on purpose: windows cut UTF-8
        case "session.markRead":
            if let r = existing(try p.req("id"))?.markRead() { try store.save(r); notify("event.session", try .from(r)) }
            return .null
        case "session.hook":
            let ls = try liveSession(p.req("id"))
            if let t = p["transcript"]?.string, !t.isEmpty { ls.transcriptPath = t }
            ls.hook(try p.req("event")); return .null
        case "session.subagents":   // Claude Code subagents of a session, from its transcript folder
            guard let t = existing(try p.req("id"))?.transcriptPath else { return .array([]) }
            let dir = URL(fileURLWithPath: t).deletingPathExtension().appendingPathComponent("subagents")
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return .array(files.filter { $0.pathExtension == "jsonl" }.compactMap { f in
                let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let head = (try? FileHandle(forReadingFrom: f)).flatMap { h in try? h.read(upToCount: 16_384) } ?? Data()
                var title = "Subagent"
                for line in head.split(separator: 0x0A) {
                    guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(line)), v["type"]?.string == "user" else { continue }
                    let c = v["message"]?["content"]
                    if let s = c?.string ?? c?.array?.first(where: { $0["type"]?.string == "text" })?["text"]?.string { title = String(s.prefix(80)); break }
                }
                return .obj(["id": .string(f.deletingPathExtension().lastPathComponent), "title": .string(title),
                             "active": .bool(Date().timeIntervalSince(mod) < 15), "updated": .double(mod.timeIntervalSince1970)])
            }.sorted { ($0["updated"].flatMap { if case .double(let d) = $0 { d } else { nil } } ?? 0) > ($1["updated"].flatMap { if case .double(let d) = $0 { d } else { nil } } ?? 0) })

        // MARK: git
        case "git.status": return try .from(Git.status(cwd(forWorktree: p.req("id")).path))
        case "git.diff":
            let w = try cwd(forWorktree: p.req("id"))
            let src: DiffSource
            switch p["source"]?.string ?? "all" {
            case "unstaged": src = .unstaged
            case "staged": src = .staged
            case "branch":
                let base = try store.repo(w.repoId)?.baseBranch ?? "main"
                src = .branch(base: p["base"]?.string ?? base)
            case "commit": src = .commit(try p.req("commit"))
            default: src = .allUncommitted
            }
            return try .from(Git.diff(w.path, source: src, file: p["file"]?.string))
        case "git.log":
            let w = try cwd(forWorktree: p.req("id"))
            let base = try store.repo(w.repoId)?.baseBranch
            return .array(try Git.log(w.path, base: p["all"]?.bool == true ? nil : base).map { .obj(["hash": .string($0.hash), "subject": .string($0.subject)]) })
        case "git.stage", "git.unstage":
            let w = try cwd(forWorktree: p.req("id"))
            let files = (p["files"]?.array ?? []).compactMap(\.string)
            if method == "git.stage" { try Git.stage(w.path, files: files) } else { try Git.unstage(w.path, files: files) }
            return .null
        case "git.hunk":   // stage/unstage one hunk: {id, file, hunk, reverse}
            let w = try cwd(forWorktree: p.req("id")); let file = try p.req("file")
            let rev = p["reverse"]?.bool == true
            guard let d = try Git.diff(w.path, source: rev ? .staged : .unstaged, file: file).first, let i = p["hunk"]?.int, d.hunks.indices.contains(i)
            else { throw RPCError.invalidParams("no such hunk") }
            try Git.applyHunk(w.path, diff: d, hunk: i, reverse: rev); return .null
        case "git.commit":
            return .string(try Git.commit(cwd(forWorktree: p.req("id")).path, message: p.req("message"), all: p["all"]?.bool == true))
        case "git.push":
            let w = try cwd(forWorktree: p.req("id")); try Git.push(w.path, branch: w.branch); return .null
        case "git.merge":   // merge worktree branch into the repo's base branch (main checkout)
            let w = try cwd(forWorktree: p.req("id"))
            guard let r = try store.repo(w.repoId) else { throw RPCError.invalidParams("no repo") }
            if try Git.isDirty(w.path) { throw RPCError.invalidParams("worktree has uncommitted changes") }
            let res = try Git.merge(branch: w.branch, into: r.path, keepConflicts: p["keepConflicts"]?.bool == true)
            return .obj(["merged": .bool(res.merged), "conflicts": .array(res.conflicts.map { .string($0) })])

        // MARK: files
        case "files.list": return try .from(ProjectFiles.list(cwd(forWorktree: p.req("id")).path))
        case "files.search":
            return try .from(ProjectFiles.search(cwd(forWorktree: p.req("id")).path, query: p.req("query"),
                                                 regex: p["regex"]?.bool == true, caseSensitive: p["case"]?.bool == true))

        // MARK: review comments
        case "comment.add":
            let c = DiffComment(worktreeId: try p.req("id"), file: try p.req("file"), startLine: p["start"]?.int ?? 1,
                                endLine: p["end"]?.int ?? p["start"]?.int ?? 1, quote: p["quote"]?.string ?? "", text: try p.req("text"))
            try store.save(c); return try .from(c)
        case "comment.list": return try .from(store.comments(worktree: p.req("id")))
        case "comment.setState":
            guard var c = try store.db.read({ try DiffComment.fetchOne($0, key: p.req("id")) }) else { throw RPCError.invalidParams("no comment") }
            c.state = DiffComment.State(rawValue: try p.req("state")) ?? .open; try store.save(c); return .null
        case "comment.send":   // all open comments -> one message into the agent's terminal
            let w = try cwd(forWorktree: p.req("id"))
            let open = try store.comments(worktree: w.id).filter { $0.state == .open }
            guard !open.isEmpty else { return .int(0) }
            try handleSync("session.send", .obj(["id": .string(try p.req("session")), "text": .string(ReviewMessage.compose(branch: w.branch, comments: open))]), conn: conn)
            for var c in open { c.state = .sent; try store.save(c) }
            return .int(open.count)

        // MARK: fan-out
        case "fanout.start":   // one prompt -> N agents, each in its own worktree
            guard let r = try store.repo(p.req("repoId")) else { throw RPCError.invalidParams("no repo") }
            let prompt = try p.req("prompt"), tag = p["name"]?.string ?? "fanout-\(Int(Date().timeIntervalSince1970) % 100000)"
            let agents = (p["agents"]?.array ?? []).compactMap(\.string)
            guard !agents.isEmpty else { throw RPCError.invalidParams("agents required") }
            var out: [JSONValue] = []
            for (i, a) in agents.enumerated() {
                let br = "\(tag)-\(i + 1)-\(a)"
                let path = try Git.addWorktree(repo: r.path, branch: br, base: r.baseBranch, into: root.appendingPathComponent("worktrees/\(r.name)"), copyFiles: r.copyFiles)
                let w = Worktree(repoId: r.id, branch: br, path: path, note: "fan-out: \(prompt.prefix(60))"); try store.save(w)
                var o = Launch(p); o.prompt = prompt; o.title = "\(a) #\(i + 1)"
                let s = try spawn(cwd: path, manifest: manifest(a, command: nil), worktreeId: w.id, o)
                out.append(.obj(["worktree": .string(w.id), "session": .string(s.id), "agent": .string(a)]))
            }
            notify("event.changed", "worktree")
            return .array(out)
        case "fanout.compare":   // per worktree: size of change + optional test result
            var rows: [JSONValue] = []
            for idv in p["ids"]?.array ?? [] {
                guard let id = idv.string else { continue }
                let w = try cwd(forWorktree: id)
                let base = try store.repo(w.repoId)?.baseBranch ?? "main"
                let d = try Git.diff(w.path, source: .allUncommitted).count > 0 ? Git.diff(w.path, source: .allUncommitted) : Git.diff(w.path, source: .branch(base: base))
                var row: [String: JSONValue] = ["id": .string(id), "branch": .string(w.branch), "files": .int(d.count),
                    "additions": .int(d.reduce(0) { $0 + $1.additions }), "deletions": .int(d.reduce(0) { $0 + $1.deletions })]
                if p["test"]?.bool == true, let t = try? handleSync("worktree.test", .obj(["id": .string(id)]), conn: conn) { row["tests"] = t["passed"] ?? .null }
                rows.append(.object(row))
            }
            return .array(rows)
        case "fanout.accept":   // merge the winner, archive the rest
            let winner = try p.req("id")
            let res = try handleSync("git.merge", .obj(["id": .string(winner)]), conn: conn)
            guard res["merged"]?.bool == true else { return res }
            for idv in p["others"]?.array ?? [] { if let id = idv.string { _ = try handleSync("worktree.archive", .obj(["id": .string(id), "force": true]), conn: conn) } }
            return res

        default: throw RPCError.methodNotFound
        }
    }
}
