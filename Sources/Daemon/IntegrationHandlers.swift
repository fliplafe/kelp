import Foundation
import Core
import GitKit
import Integrations

/// A branch, commit or base from a client, as git will be given it: never one that reads as an option ("--output=…"
/// would make `git show` write a file). No real ref starts with "-".
func clientRef(_ v: String?) throws -> String? {
    guard let v else { return nil }
    if v.hasPrefix("-") { throw RPCError.invalidParams("“\(v)” isn't a branch or commit.") }
    return v
}

extension Store {
    /// The project and folder a method names: its workspace's (`worktreeId`), else its project's (`repoId`).
    func repoPath(_ p: JSONValue) throws -> (Repo, String) {
        if let wid = p["worktreeId"]?.string, let w = try worktree(wid), let r = try repo(w.repoId) { return (r, w.path) }
        guard let r = try repo(p.req("repoId")) else { throw RPCError.invalidParams("no repo") }
        return (r, r.path)
    }

    func repoPath(worktreeId: String?, repoId: String?) throws -> (Repo, String) {
        try repoPath(.obj(["worktreeId": worktreeId.map { .string($0) } ?? .null, "repoId": repoId.map { .string($0) } ?? .null]))
    }
}

/// What the forge and tracker methods share: remote projects refused, and the integrations' errors as the app shows them.
/// (GitHub goes through `gh`, with its auth; the trackers' clients: `Forges`.)
extension Daemon {

    /// gh / glab run in the folder here; a remote project's is only a marker under ~/.kelp, and their git would walk up to
    /// whatever repository holds it (a dotfiles home). Until they run on the host, they don't run at all: a `LocalForge`
    /// method is refused for one, or answers null when the sidebar asked by itself.
    func refuseRemoteForge(_ t: any Answered.Type, _ p: JSONValue) throws -> Data? {
        guard let forge = t as? any LocalForge.Type, (try? store.repoPath(p)).map({ remotes.of($0.1) != nil }) == true else { return nil }
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
extension GitLabStatus: LocalForge {}
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
