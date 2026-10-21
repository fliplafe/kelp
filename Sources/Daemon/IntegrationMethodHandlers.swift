import Foundation
import Core
import GitKit
import Integrations

/// A method that waits on a web API (Linear, Jira, Bitbucket): async, with its gh / git calls through `offload`.
/// `handle(_:conn:)` for one that reports progress to the asking connection (repo.clone).
protocol AsyncHandled: Answered {
    func handle(_ d: Daemon) async throws -> Result
    func handle(_ d: Daemon, conn: Int) async throws -> Result
}

extension AsyncHandled {
    static var inOrder: Bool { false }
    func handle(_ d: Daemon, conn: Int) async throws -> Result { try await handle(d) }

    static func answer(_ p: JSONValue, _ d: Daemon, conn: Int) async throws -> Data { try JSONEncoder().encode(await decoded(p).handle(d, conn: conn)) }
}

extension Daemon {
    func repoPath(worktreeId: String?, repoId: String?) throws -> (Repo, String) {
        try repoPath(.obj(["worktreeId": worktreeId.map { .string($0) } ?? .null, "repoId": repoId.map { .string($0) } ?? .null]))
    }

    /// The branch checked out in the folder now (a workspace's record can be stale after a switch).
    func checkedOut(_ w: Worktree) -> String {
        (try? Git.currentBranch(w.path)) ?? w.branch
    }

    static let bitbucketNeedsCredentials = RPCError.invalidParams("This repo is on Bitbucket — add credentials in Settings › Integrations")
}

// MARK: gh / glab / git only

extension GitHubBranchPR: Handled {
    func handle(_ d: Daemon) throws -> GitHub.PullRequest? {
        let w = try d.cwd(forWorktree: worktreeId), branch = d.checkedOut(w), key = w.path + "@" + branch
        if let hit = d.prCache.withLock({ $0[key] }), Date().timeIntervalSince(hit.at) < 120 { return hit.value }
        // nil: no PR, or gh couldn't tell (try? flattens to one optional)
        let v = GitLab.isGitLab(cwd: w.path) ? try? GitLab.mergeRequest(cwd: w.path, branch: branch) : try? GitHub.pullRequest(cwd: w.path, branch: branch)
        d.prCache.withLock { $0[key] = (Date(), v) }
        return v
    }
}

extension GitHubForge: Handled {
    func handle(_ d: Daemon) throws -> String {
        let (_, path) = try d.repoPath(worktreeId: worktreeId, repoId: repoId)
        return GitLab.isGitLab(cwd: path) ? "gitlab" : BitbucketClient.slug(cwd: path) != nil ? "bitbucket" : "github"
    }
}

extension CIRunsList: Handled {
    func handle(_ d: Daemon) throws -> Result {
        let w = try d.cwd(forWorktree: worktreeId), branch = d.checkedOut(w)
        return Result(branch: branch, runs: try CIRuns.runs(cwd: w.path, branch: branch),
                      workflows: GitLab.isGitLab(cwd: w.path) ? [] : CIRuns.dispatchable(repo: w.path))
    }
}
extension CIJobs: Handled { func handle(_ d: Daemon) throws -> [CIRuns.Job] { try CIRuns.jobs(cwd: d.cwd(forWorktree: worktreeId).path, run: run ?? 0) } }
extension CILog: Handled { func handle(_ d: Daemon) throws -> String { try CIRuns.log(cwd: d.cwd(forWorktree: worktreeId).path, job: job ?? 0) } }
extension CIRerun: Handled {
    func handle(_ d: Daemon) throws -> Done { try CIRuns.rerunFailed(cwd: d.cwd(forWorktree: worktreeId).path, run: run ?? 0); return Done() }
}
extension CIDispatch: Handled {
    func handle(_ d: Daemon) throws -> Done {
        try CIRuns.dispatch(cwd: d.cwd(forWorktree: worktreeId).path, workflow: workflow, branch: d.ref(branch) ?? "", inputs: inputs ?? [:])
        return Done()
    }
}

extension GitHubStatus: Handled {
    func handle(_ d: Daemon) throws -> Result {
        let a = GitHub.account()
        return Result(installed: a.installed, user: a.user)
    }
}
extension GitLabStatus: Handled {
    func handle(_ d: Daemon) throws -> Result {
        let a = GitLab.account()
        return Result(installed: a.installed, user: a.user)
    }
}
extension GitHubIssues: Handled {
    func handle(_ d: Daemon) throws -> [GitHub.Issue] {
        let (_, path) = try d.repoPath(worktreeId: worktreeId, repoId: repoId)
        if GitLab.isGitLab(cwd: path) { return try GitLab.issues(cwd: path, mine: filter == "mine") }
        return try GitHub.issues(cwd: path, mine: filter == "mine")
    }
}
extension GitHubChecks: Handled {
    func handle(_ d: Daemon) throws -> [GitHub.Check] { try GitHub.checks(cwd: d.repoPath(worktreeId: worktreeId, repoId: repoId).1, pr: pr ?? 0) }
}
extension GitHubFailedLog: Handled {
    func handle(_ d: Daemon) throws -> String { try GitHub.failedLog(cwd: d.repoPath(worktreeId: worktreeId, repoId: repoId).1, runId: runId ?? 0) }
}
extension GitHubReviewComments: Handled {
    func handle(_ d: Daemon) throws -> [GitHub.ReviewComment] { try GitHub.reviewComments(cwd: d.repoPath(worktreeId: worktreeId, repoId: repoId).1, pr: pr ?? 0) }
}
extension GitHubProjects: Handled {
    func handle(_ d: Daemon) throws -> [GitHub.Project] { try GitHub.projects(cwd: d.repoPath(worktreeId: worktreeId, repoId: repoId).1) }
}
extension GitHubProjectItems: Handled {
    func handle(_ d: Daemon) throws -> [GitHub.ProjectItem] { try GitHub.projectItems(owner: owner, number: number ?? 0) }
}

// MARK: also a web API

extension GitHubPRs: AsyncHandled {
    func handle(_ d: Daemon) async throws -> [GitHub.PullRequest] {
        let (_, path) = try d.repoPath(worktreeId: worktreeId, repoId: repoId)
        if let slug = try await d.offload({ BitbucketClient.slug(cwd: path) }) {
            guard let bb = await d.bitbucketClient() else { throw Daemon.bitbucketNeedsCredentials }
            return try await bb.pullRequests(workspace: slug.workspace, repo: slug.repo)
        }
        let filter = filter
        return try await d.offload {
            if GitLab.isGitLab(cwd: path) { return try GitLab.mergeRequests(cwd: path, mine: filter == "mine") }
            let f: GitHub.PRFilter = filter == "mine" ? .mine : filter == "review" ? .reviewRequested : .open
            return try GitHub.pullRequests(cwd: path, filter: f)
        }
    }
}

extension GitHubPRCreate: AsyncHandled {
    func handle(_ d: Daemon) async throws -> Result {
        guard let w = try d.store.worktree(worktreeId), let r = try d.store.repo(w.repoId) else { throw RPCError.invalidParams("no worktree") }
        let path = w.path, draft = draft == true
        try await d.offload { try Git.remote(path, .push) }   // the branch checked out now
        let branch = try await d.offload { d.checkedOut(w) }   // and the PR's source (the record can be stale after a switch)
        var title = title ?? "", body = body ?? ""
        let link = w.issue.isEmpty ? nil : (w.issue.hasPrefix("#") ? "Fixes \(w.issue)" : "Refs \(w.issue)")
        if title.isEmpty || body.isEmpty {
            let cmpBase = w.base.isEmpty ? r.baseBranch : w.base
            let commits = try await d.offload { try Git.log(path, base: cmpBase).map(\.subject) }
            if title.isEmpty { title = commits.last ?? branch }
            if body.isEmpty { body = commits.map { "- \($0)" }.joined(separator: "\n") + (link.map { "\n\n\($0)" } ?? "") }
        } else if let link, !body.contains(w.issue) { body += "\n\n\(link)" }
        // Stacked: a worktree cut from another feature branch opens its PR against that branch.
        let prBase = w.base.isEmpty ? r.baseBranch : w.base
        if prBase != r.baseBranch, !body.contains("Stacked on") { body = "Stacked on `\(prBase)`.\n\n" + body }
        let url: String
        if let slug = try await d.offload({ BitbucketClient.slug(cwd: path) }) {
            guard let bb = await d.bitbucketClient() else { throw Daemon.bitbucketNeedsCredentials }
            url = try await bb.createPR(workspace: slug.workspace, repo: slug.repo, title: title, body: body, source: branch, destination: prBase)
        } else if try await d.offload({ GitLab.isGitLab(cwd: path) }) {
            url = try await d.offload { [title, body] in try GitLab.createMR(cwd: path, title: title, body: body, base: prBase, draft: draft) }
        } else {
            url = try await d.offload { [title, body] in try GitHub.createPR(cwd: path, title: title, body: body, base: prBase, draft: draft) }
        }
        try d.store.update(Worktree.self, w.id) { $0.prURL = url; $0.prNumber = Int(url.split(separator: "/").last ?? "") }
        d.notify(ChangedEvent.worktree)
        await d.moveLinear(w, to: .inReview)
        await d.moveJira(w, toName: "review", category: "indeterminate")
        return Result(url: url, title: title)
    }
}

extension GitHubPRMerge: AsyncHandled {
    func handle(_ d: Daemon) async throws -> Done {
        guard let w = try d.store.worktree(worktreeId), let n = pr ?? w.prNumber else { throw RPCError.invalidParams("no PR linked") }
        let how = method ?? "squash"
        if let slug = try await d.offload({ BitbucketClient.slug(cwd: w.path) }) {
            // Bitbucket's API or nothing: gh would look for the number on whatever GitHub repository it found.
            guard let bb = await d.bitbucketClient() else { throw Daemon.bitbucketNeedsCredentials }
            try await bb.merge(workspace: slug.workspace, repo: slug.repo, id: n)
        } else if try await d.offload({ GitLab.isGitLab(cwd: w.path) }) {
            try await d.offload { try GitLab.mergeMR(cwd: w.path, number: n, squash: how == "squash") }
        } else {
            let m = GitHub.MergeMethod(rawValue: how) ?? .squash
            try await d.offload { try GitHub.mergePR(cwd: w.path, number: n, method: m) }
        }
        await d.moveLinear(w, to: .done)
        await d.moveJira(w, toName: "done", category: "done")
        d.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension LinearSetKey: AsyncHandled {
    func handle(_ d: Daemon) async throws -> LinearUser? {
        if key.isEmpty { try await d.keepSecret("", account: Daemon.linearKeyAccount); return nil }
        let me = try await LinearClient(apiKey: key).viewer()   // validate before saving
        try await d.keepSecret(key, account: Daemon.linearKeyAccount)
        return me
    }
}
extension LinearStatus: AsyncHandled {
    func handle(_ d: Daemon) async throws -> Result {
        guard let l = await d.linearClient() else { return Result(connected: false) }
        let me = try? await l.viewer()
        return Result(connected: me != nil, name: me?.name ?? "")
    }
}
extension LinearIssues: AsyncHandled {
    func handle(_ d: Daemon) async throws -> [LinearIssue] {
        guard let l = await d.linearClient() else { throw RPCError.invalidParams("Linear is not connected (Settings › Integrations)") }
        if let teamId { return try await l.teamIssues(teamId: teamId) }
        return try await l.myIssues()
    }
}
extension LinearTeams: AsyncHandled {
    func handle(_ d: Daemon) async throws -> [LinearTeam] { guard let l = await d.linearClient() else { return [] }; return try await l.teams() }
}
extension LinearStates: AsyncHandled {
    func handle(_ d: Daemon) async throws -> [LinearState] {
        guard let l = await d.linearClient() else { return [] }
        return try await l.workflowStates(teamId: teamId)
    }
}
extension LinearSetState: AsyncHandled {
    func handle(_ d: Daemon) async throws -> Done {
        guard let l = await d.linearClient() else { throw RPCError.invalidParams("Linear is not connected") }
        try await l.setState(issueId: issueId, stateId: stateId)
        return Done()
    }
}

extension JiraSetCredentials: AsyncHandled {
    func handle(_ d: Daemon) async throws -> Account? {
        if token.isEmpty { try await d.keepSecret("", account: Daemon.jiraAccount); return nil }
        let name = try await JiraClient(site: site, email: email, token: token).myself()   // validate before saving
        try await d.keepSecret(String(decoding: try JSONEncoder().encode(["site": site, "email": email, "token": token]), as: UTF8.self), account: Daemon.jiraAccount)
        return Account(name: name)
    }
}
extension JiraStatus: AsyncHandled {
    func handle(_ d: Daemon) async throws -> Result {
        guard let j = await d.jiraClient() else { return Result(connected: false) }
        let n = try? await j.myself()
        return Result(connected: n != nil, name: n ?? "", site: j.site)
    }
}
extension JiraIssues: AsyncHandled {
    func handle(_ d: Daemon) async throws -> [JiraIssue] {
        guard let j = await d.jiraClient() else { throw RPCError.invalidParams("Jira is not connected (Settings › Integrations)") }
        return try await j.search(jql: jql ?? JiraClient.myOpenJQL)
    }
}
extension JiraTransitions: AsyncHandled {
    func handle(_ d: Daemon) async throws -> [JiraTransition] { guard let j = await d.jiraClient() else { return [] }; return try await j.transitions(key: key) }
}
extension JiraTransitionIssue: AsyncHandled {
    func handle(_ d: Daemon) async throws -> Done {
        guard let j = await d.jiraClient() else { throw RPCError.invalidParams("Jira is not connected") }
        try await j.transition(key: key, id: id)
        return Done()
    }
}

extension BitbucketSetCredentials: AsyncHandled {
    func handle(_ d: Daemon) async throws -> Done {
        try await d.keepSecret(token.isEmpty ? "" : String(decoding: try JSONEncoder().encode(["user": user, "token": token]), as: UTF8.self),
                               account: Daemon.bitbucketAccount)
        return Done()
    }
}
extension BitbucketStatus: AsyncHandled {
    func handle(_ d: Daemon) async throws -> Result { Result(connected: await d.bitbucketClient() != nil) }
}

extension Daemon {
    static let integrationMethods: [any Handled.Type] = [GitHubBranchPR.self, GitHubForge.self, CIRunsList.self, CIJobs.self, CILog.self,
        CIRerun.self, CIDispatch.self, GitHubStatus.self, GitLabStatus.self, GitHubIssues.self, GitHubChecks.self, GitHubFailedLog.self,
        GitHubReviewComments.self, GitHubProjects.self, GitHubProjectItems.self]
    static let asyncMethods: [any AsyncHandled.Type] = [GitHubPRs.self, GitHubPRCreate.self, GitHubPRMerge.self, LinearSetKey.self,
        LinearStatus.self, LinearIssues.self, LinearTeams.self, LinearStates.self, LinearSetState.self, JiraSetCredentials.self, JiraStatus.self,
        JiraIssues.self, JiraTransitions.self, JiraTransitionIssue.self, BitbucketSetCredentials.self, BitbucketStatus.self,
        AgentsVersions.self, TaskFromIssue.self, RepoClone.self, RepoCloneCancel.self]
}
