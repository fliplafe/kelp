import Foundation
import Core
import GitKit
import Integrations

/// GitHub (through `gh`, same auth) and Linear (API key in the keychain) RPCs.
extension Daemon {
    static let linearKeyAccount = "linear-api-key"

    func repoPath(_ p: JSONValue) throws -> (Repo, String) {
        if let wid = p["worktreeId"]?.string, let w = try store.worktree(wid), let r = try store.repo(w.repoId) { return (r, w.path) }
        guard let r = try store.repo(p.req("repoId")) else { throw RPCError.invalidParams("no repo") }
        return (r, r.path)
    }

    var linear: LinearClient? { Keychain.get(Self.linearKeyAccount).map(LinearClient.init(apiKey:)) }

    /// Jira / Bitbucket credentials: one JSON blob each in the keychain.
    static let jiraAccount = "jira", bitbucketAccount = "bitbucket"
    var jira: JiraClient? {
        guard let s = Keychain.get(Self.jiraAccount), let v = try? JSONDecoder().decode([String: String].self, from: Data(s.utf8)),
              let site = v["site"], let email = v["email"], let token = v["token"] else { return nil }
        return JiraClient(site: site, email: email, token: token)
    }
    var bitbucket: BitbucketClient? {
        guard let s = Keychain.get(Self.bitbucketAccount), let v = try? JSONDecoder().decode([String: String].self, from: Data(s.utf8)),
              let u = v["user"], let t = v["token"] else { return nil }
        return BitbucketClient(user: u, token: t)
    }
    /// The keychain can keep a caller waiting (a locked login keychain): these read it off the cooperative pool.
    func linearClient() async -> LinearClient? { try? await offload { [self] in linear } }
    func jiraClient() async -> JiraClient? { try? await offload { [self] in jira } }
    func bitbucketClient() async -> BitbucketClient? { try? await offload { [self] in bitbucket } }

    /// Jira issues linked to a worktree ("ENG-12") move along with the PR, like Linear.
    func moveJira(_ w: Worktree, toName hint: String, category: String) async {
        guard let j = await jiraClient(), w.issue.range(of: #"^[A-Z][A-Z0-9]+-\d+$"#, options: .regularExpression) != nil, w.linearIssueId.isEmpty else { return }
        try? await j.move(key: w.issue, toName: hint, category: category)
    }

    /// Move a linked Linear issue to a workflow state kind; quiet no-op without a key or link.
    func moveLinear(_ w: Worktree, to kind: LinearClient.StateKind) async {
        guard !w.linearIssueId.isEmpty, let l = await linearClient(),
              // Limit: finds the team via my issues; query the issue by id if tasks assigned to others need moving
              let issue = try? await l.myIssues().first(where: { $0.id == w.linearIssueId }) ?? nil,
              let states = try? await l.workflowStates(teamId: issue.team.id),
              let st = LinearClient.stateFor(kind: kind, in: states) else { return }
        try? await l.setState(issueId: w.linearIssueId, stateId: st.id)
    }

    func handleIntegration(_ method: String, _ p: JSONValue, conn: Int) async throws -> JSONValue? {
        do {
            if let r = try await offload({ [self] in try integrationBlocking(method, p) }) { return r }
            return try await integration(method, p, conn: conn)
        }
        catch let e as GitHubError { throw RPCError.internalError(e.description) }
        catch let e as LinearError { throw RPCError.internalError(e.description) }
        catch let e as JiraError { throw RPCError.internalError(e.description) }
        catch let e as BitbucketError { throw RPCError.internalError(e.description) }
    }

    /// What only runs gh / glab / git (see `offload`).
    private func integrationBlocking(_ method: String, _ p: JSONValue) throws -> JSONValue? {
        switch method {
        case "github.branchPR":   // {worktreeId} → the PR of the branch checked out there (cached for two minutes)
            let w = try cwd(forWorktree: p.req("worktreeId"))
            let branch = (try? Git.run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: w.path))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? w.branch
            let key = w.path + "@" + branch
            if let hit = lock.withLock({ prCache[key] }), Date().timeIntervalSince(hit.at) < 120 { return hit.value }
            let found = GitLab.isGitLab(cwd: w.path) ? try? GitLab.mergeRequest(cwd: w.path, branch: branch) : try? GitHub.pullRequest(cwd: w.path, branch: branch)
            let v: JSONValue = found.flatMap { try? JSONValue.from($0) } ?? .null   // try? flattens: one optional
            lock.withLock { prCache[key] = (Date(), v) }
            return v
        case "github.forge":   // {repoId} → "github" | "gitlab" | "bitbucket": what the panels call things
            let (_, path) = try repoPath(p)
            return .string(GitLab.isGitLab(cwd: path) ? "gitlab" : BitbucketClient.slug(cwd: path) != nil ? "bitbucket" : "github")

        // MARK: CI runs of the branch checked out in a workspace
        case "ci.runs":
            let w = try cwd(forWorktree: p.req("worktreeId"))
            let branch = (try? Git.run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: w.path))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? w.branch
            return .obj(["branch": .string(branch), "runs": try .from(CIRuns.runs(cwd: w.path, branch: branch)),
                         "workflows": try .from(GitLab.isGitLab(cwd: w.path) ? [] : CIRuns.dispatchable(repo: w.path))])
        case "ci.jobs": return try .from(CIRuns.jobs(cwd: cwd(forWorktree: p.req("worktreeId")).path, run: p["run"]?.int ?? 0))
        case "ci.log": return .string(try CIRuns.log(cwd: cwd(forWorktree: p.req("worktreeId")).path, job: p["job"]?.int ?? 0))
        case "ci.rerun": try CIRuns.rerunFailed(cwd: cwd(forWorktree: p.req("worktreeId")).path, run: p["run"]?.int ?? 0); return .null
        case "ci.dispatch":
            let w = try cwd(forWorktree: p.req("worktreeId"))
            var inputs: [String: String] = [:]
            if case .object(let o)? = p["inputs"] { for (k, v) in o { inputs[k] = v.string ?? "" } }
            try CIRuns.dispatch(cwd: w.path, workflow: p.req("workflow"), branch: p.req("branch"), inputs: inputs); return .null

        case "github.status":
            let a = GitHub.account()
            return .obj(["installed": .bool(a.installed), "user": a.user.map { .string($0) } ?? .null])
        case "github.issues":
            let (_, path) = try repoPath(p)
            if GitLab.isGitLab(cwd: path) { return try .from(GitLab.issues(cwd: path, mine: p["filter"]?.string == "mine")) }
            return try .from(GitHub.issues(cwd: path, filter: p["filter"]?.string == "mine" ? .mine : .open))
        case "github.checks":
            let (_, path) = try repoPath(p); return try .from(GitHub.checks(cwd: path, pr: p["pr"]?.int ?? 0))
        case "github.failedLog":
            let (_, path) = try repoPath(p); return .string(try GitHub.failedLog(cwd: path, runId: p["runId"]?.int ?? 0))
        case "github.reviewComments":
            let (_, path) = try repoPath(p); return try .from(GitHub.reviewComments(cwd: path, pr: p["pr"]?.int ?? 0))
        case "github.projects":
            let (_, path) = try repoPath(p); return try .from(GitHub.projects(cwd: path))
        case "github.projectItems":
            return try .from(GitHub.projectItems(owner: p.req("owner"), number: p["number"]?.int ?? 0))
        default: return nil
        }
    }

    /// What also waits on a web API; its gh / git calls still go through `offload`, one by one.
    private func integration(_ method: String, _ p: JSONValue, conn: Int) async throws -> JSONValue? {
        switch method {
        case "github.prs":
            let (_, path) = try repoPath(p)
            if let slug = try await offload({ BitbucketClient.slug(cwd: path) }) {
                guard let bb = await bitbucketClient() else { throw RPCError.invalidParams("This repo is on Bitbucket — add credentials in Settings › Integrations") }
                return try .from(await bb.pullRequests(workspace: slug.workspace, repo: slug.repo))
            }
            return try await offload { () throws -> JSONValue in
                if GitLab.isGitLab(cwd: path) { return try .from(GitLab.mergeRequests(cwd: path, mine: p["filter"]?.string == "mine")) }
                let f: GitHub.PRFilter = p["filter"]?.string == "mine" ? .mine : p["filter"]?.string == "review" ? .reviewRequested : .open
                return try .from(GitHub.pullRequests(cwd: path, filter: f))
            }
        case "github.pr-create":   // push, title/body from the commits if not given, open the PR, link it
            guard var w = try store.worktree(p.req("worktreeId")), let r = try store.repo(w.repoId) else { throw RPCError.invalidParams("no worktree") }
            let path = w.path
            try await offload { try Git.remote(path, .push) }   // the branch checked out now
            var title = p["title"]?.string ?? "", body = p["body"]?.string ?? ""
            let link = w.issue.isEmpty ? nil : (w.issue.hasPrefix("#") ? "Fixes \(w.issue)" : "Refs \(w.issue)")
            if title.isEmpty || body.isEmpty {
                let cmpBase = w.base.isEmpty ? r.baseBranch : w.base
                let commits = try await offload { try Git.log(path, base: cmpBase).map(\.subject) }
                if title.isEmpty { title = commits.last ?? w.branch }
                if body.isEmpty { body = commits.map { "- \($0)" }.joined(separator: "\n") + (link.map { "\n\n\($0)" } ?? "") }
            } else if let link, !body.contains(w.issue) { body += "\n\n\(link)" }
            // Stacked: a worktree cut from another feature branch opens its PR against that branch.
            let prBase = w.base.isEmpty ? r.baseBranch : w.base
            if prBase != r.baseBranch, !body.contains("Stacked on") { body = "Stacked on `\(prBase)`.\n\n" + body }
            let url: String
            if let slug = try await offload({ BitbucketClient.slug(cwd: path) }) {
                guard let bb = await bitbucketClient() else { throw RPCError.invalidParams("This repo is on Bitbucket — add credentials in Settings › Integrations") }
                url = try await bb.createPR(workspace: slug.workspace, repo: slug.repo, title: title, body: body, source: w.branch, destination: prBase)
            } else if try await offload({ GitLab.isGitLab(cwd: path) }) {
                url = try await offload { [title, body] in try GitLab.createMR(cwd: path, title: title, body: body, base: prBase, draft: p["draft"]?.bool == true) }
            } else {
                url = try await offload { [title, body] in try GitHub.createPR(cwd: path, title: title, body: body, base: prBase, draft: p["draft"]?.bool == true) }
            }
            try store.updateWorktree(w.id) { $0.prURL = url; $0.prNumber = Int(url.split(separator: "/").last ?? "") }
            notify("event.changed", "worktree")
            await moveLinear(w, to: .inReview)
            await moveJira(w, toName: "review", category: "indeterminate")
            return .obj(["url": .string(url), "title": .string(title)])

        case "github.pr-merge":
            guard let w = try store.worktree(p.req("worktreeId")), let n = p["pr"]?.int ?? w.prNumber else { throw RPCError.invalidParams("no PR linked") }
            if let slug = try await offload({ BitbucketClient.slug(cwd: w.path) }), let bb = await bitbucketClient() {
                try await bb.merge(workspace: slug.workspace, repo: slug.repo, id: n)
            } else if try await offload({ GitLab.isGitLab(cwd: w.path) }) {
                let squash = (p["method"]?.string ?? "squash") == "squash"
                try await offload { try GitLab.mergeMR(cwd: w.path, number: n, squash: squash) }
            } else {
                let m = GitHub.MergeMethod(rawValue: p["method"]?.string ?? "squash") ?? .squash
                try await offload { try GitHub.mergePR(cwd: w.path, number: n, method: m, deleteBranch: false) }
            }
            await moveLinear(w, to: .done)
            await moveJira(w, toName: "done", category: "done")
            notify("event.changed", "worktree")
            return .null

        case "linear.setKey":
            let key = try p.req("key")
            if key.isEmpty { Keychain.delete(Self.linearKeyAccount); return .null }
            let me = try await LinearClient(apiKey: key).viewer()   // validate before saving
            try Keychain.set(key, account: Self.linearKeyAccount)
            return try .from(me)
        case "linear.status":
            guard let l = await linearClient() else { return .obj(["connected": false]) }
            let me = try? await l.viewer()
            return .obj(["connected": .bool(me != nil), "name": .string(me?.name ?? "")])
        case "linear.issues":
            guard let l = await linearClient() else { throw RPCError.invalidParams("Linear is not connected (Settings › Integrations)") }
            if let t = p["teamId"]?.string { return try .from(await l.teamIssues(teamId: t)) }
            return try .from(await l.myIssues())
        case "linear.teams":
            guard let l = await linearClient() else { return .array([]) }; return try .from(await l.teams())
        case "linear.states":
            guard let l = await linearClient() else { return .array([]) }; return try .from(await l.workflowStates(teamId: p.req("teamId")))
        case "linear.setState":
            guard let l = await linearClient() else { throw RPCError.invalidParams("Linear is not connected") }
            try await l.setState(issueId: p.req("issueId"), stateId: p.req("stateId")); return .null

        case "jira.setCredentials":
            let site = try p.req("site"), email = try p.req("email"), token = try p.req("token")
            if token.isEmpty { Keychain.delete(Self.jiraAccount); return .null }
            let name = try await JiraClient(site: site, email: email, token: token).myself()   // validate before saving
            try Keychain.set(String(decoding: try JSONEncoder().encode(["site": site, "email": email, "token": token]), as: UTF8.self), account: Self.jiraAccount)
            return .obj(["name": .string(name)])
        case "jira.status":
            guard let j = await jiraClient() else { return .obj(["connected": false]) }
            let n = try? await j.myself()
            return .obj(["connected": .bool(n != nil), "name": .string(n ?? ""), "site": .string(j.site)])
        case "jira.issues":
            guard let j = await jiraClient() else { throw RPCError.invalidParams("Jira is not connected (Settings › Integrations)") }
            return try .from(await j.search(jql: p["jql"]?.string ?? JiraClient.myOpenJQL))
        case "jira.transitions":
            guard let j = await jiraClient() else { return .array([]) }
            return try .from(await j.transitions(key: p.req("key")))
        case "jira.transition":
            guard let j = await jiraClient() else { throw RPCError.invalidParams("Jira is not connected") }
            try await j.transition(key: p.req("key"), id: p.req("id")); return .null
        case "bitbucket.setCredentials":
            let u = try p.req("user"), t = try p.req("token")
            if t.isEmpty { Keychain.delete(Self.bitbucketAccount); return .null }
            try Keychain.set(String(decoding: try JSONEncoder().encode(["user": u, "token": t]), as: UTF8.self), account: Self.bitbucketAccount)
            return .null
        case "bitbucket.status": return .obj(["connected": .bool(await bitbucketClient() != nil)])

        case "task.fromIssue":   // issue / Linear task -> branch with its number, worktree, agent briefed with the description
            guard let r = try store.repo(p.req("repoId")) else { throw RPCError.invalidParams("no repo") }
            let ref = try p.req("ref"), title = try p.req("title"), body = p["body"]?.string ?? "", url = p["url"]?.string ?? ""
            var branch = p["branch"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? IssueRef.branchName(ref.hasPrefix("#") ? String(ref.dropFirst()) : ref.lowercased(), title: title)
            if let prefix = p["branchPrefix"]?.string, !prefix.isEmpty, !branch.hasPrefix(prefix) { branch = prefix + branch }
            let unique = try await offload { [branch] in
                var unique = branch, n = 2
                while Git.branchExists(r.path, unique) { unique = "\(branch)-\(n)"; n += 1 }
                return unique
            }
            let wv = try await handle("worktree.create", .obj(["repoId": .string(r.id), "branch": .string(unique), "note": .string("\(ref) \(title)"), "tabs": false]), conn: conn)
            // The record, the repo's config and the agent's PTY: disk and a process, through `offload` like the rest.
            let (w, s) = try await offload { [self] () throws -> (Worktree, Session) in
                guard let w = try store.updateWorktree(try wv.req("id"), {
                    $0.issue = ref; $0.issueURL = url; $0.linearIssueId = p["linearId"]?.string ?? ""
                }) else { throw RPCError.internalError("worktree vanished") }
                let cfg = trustedConfig(r.path)   // its issueCommand / recipes only once the user trusts the file
                let vars = ["title": title, "body": body, "url": url, "ref": ref, "branch": unique]
                var prompt = cfg.issueCommand.map { t in vars.reduce(t) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) } }
                    ?? Recipes.render("issue", config: cfg, vars: vars)
                if let extra = p["prompt"]?.string, !extra.isEmpty { prompt += "\n\n" + extra }
                var o = Launch(p); o.prompt = prompt; o.title = "\(ref) \(title)".prefix(48).description
                return (w, try spawn(cwd: w.path, manifest: manifest(p["agent"]?.string ?? "claude", command: nil), worktreeId: w.id, o))
            }
            await moveLinear(w, to: .inProgress)
            await moveJira(w, toName: "progress", category: "indeterminate")
            notify("event.changed", "worktree")
            return .obj(["worktree": try .from(w), "session": try .from(s)])
        default: return nil
        }
    }
}
