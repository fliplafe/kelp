import Foundation
import Core
import GitKit
import Integrations

/// GitHub (through `gh`, same auth) and Linear (API key in the keychain) RPCs.
extension Daemon {
    static let linearKeyAccount = "linear-api-key"

    /// A branch, commit or base from a client, as git will be given it: never one that reads as an option ("--output=…"
    /// would make `git show` write a file). No real ref starts with "-".
    func ref(_ v: String?) throws -> String? {
        guard let v else { return nil }
        if v.hasPrefix("-") { throw RPCError.invalidParams("“\(v)” isn't a branch or commit.") }
        return v
    }

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
        do { try await j.move(key: w.issue, toName: hint, category: category) }
        catch { Log.rpc.notice("Jira issue \(w.issue, privacy: .public) didn't move to \(hint, privacy: .public): \(error)") }
    }

    /// Move a linked Linear issue to a workflow state kind; quiet no-op without a key or link.
    func moveLinear(_ w: Worktree, to kind: LinearClient.StateKind) async {
        guard !w.linearIssueId.isEmpty, let l = await linearClient(),
              // Limit: finds the team via my issues; query the issue by id if tasks assigned to others need moving
              let issue = try? await l.myIssues().first(where: { $0.id == w.linearIssueId }) ?? nil,
              let states = try? await l.workflowStates(teamId: issue.team.id),
              let st = LinearClient.stateFor(kind: kind, in: states) else { return }
        do { try await l.setState(issueId: w.linearIssueId, stateId: st.id) }
        catch { Log.rpc.notice("Linear issue \(w.linearIssueId, privacy: .public) didn't move: \(error)") }
    }

    /// gh / glab run in the folder here; a remote project's is only a marker under ~/.kelp, and their git would walk up to
    /// whatever repository holds it (a dotfiles home). Until they run on the host, they don't run at all: a `LocalForge`
    /// method is refused for one, or answers null when the sidebar asked by itself.
    func refuseRemoteForge(_ t: any Answered.Type, _ p: JSONValue) throws -> Data? {
        guard let forge = t as? any LocalForge.Type, (try? repoPath(p)).map({ RemoteHost.of($0.1) != nil }) == true else { return nil }
        if forge.quietOnRemote { return Data("null".utf8) }
        throw RPCError.invalidParams("Pull requests and CI aren't available for remote projects yet.")
    }

    /// The integrations' own errors, as the app shows them.
    func integrationErrors<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let e as GitHubError { throw RPCError.internalError(e.description) }
        catch let e as IntegrationError { throw RPCError.internalError(e.description) }
    }

}

/// Runs gh or glab in the project's folder (`refuseRemoteForge`): every GitHub, GitLab and CI method.
protocol LocalForge {
    /// Asked by the sidebar on its own: null for a remote project instead of an error.
    static var quietOnRemote: Bool { get }
}
extension LocalForge { static var quietOnRemote: Bool { false } }

extension GitHubBranchPR: LocalForge { static var quietOnRemote: Bool { true } }
extension GitHubForge: LocalForge { static var quietOnRemote: Bool { true } }
extension GitHubStatus: LocalForge {}
extension GitHubIssues: LocalForge {}
extension GitHubChecks: LocalForge {}
extension GitHubFailedLog: LocalForge {}
extension GitHubReviewComments: LocalForge {}
extension GitHubProjects: LocalForge {}
extension GitHubProjectItems: LocalForge {}
extension GitHubPRs: LocalForge {}
extension GitHubPRCreate: LocalForge {}
extension GitHubPRMerge: LocalForge {}
extension CIRunsList: LocalForge {}
extension CIJobs: LocalForge {}
extension CILog: LocalForge {}
extension CIRerun: LocalForge {}
extension CIDispatch: LocalForge {}
