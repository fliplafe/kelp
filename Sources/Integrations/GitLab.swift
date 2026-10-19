import Foundation
import GitKit

/// GitLab through the `glab` CLI and its login (`glab auth login`), the way GitHub goes through `gh`: merge requests,
/// issues and pipelines in GitHub's shapes, so the panels show either. Self-managed hosts work as glab knows them.
public enum GitLab {
    static let glabPath: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return (["/opt/homebrew/bin", "/usr/local/bin"] + path).map { $0 + "/glab" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// The checkout's origin is a GitLab (gitlab.com or a host with "gitlab" in its name).
    public static func isGitLab(cwd: String) -> Bool {
        ((try? Git.run(["remote", "get-url", "origin"], cwd: cwd)) ?? "").lowercased().contains("gitlab")
    }

    /// `glab api` with `:id` standing for this project (glab fills it in from the remote).
    static func api(_ path: String, cwd: String, method: String = "GET") throws -> Data {
        guard let exe = glabPath else { throw GitHubError(args: ["glab"], status: -1, stderr: "glab CLI not found (brew install glab)") }
        do { return Data(try Git.run(["api", "-X", method, path], cwd: cwd, executable: exe).utf8) }
        catch let e as GitError { throw GitHubError(args: e.args, status: e.status, stderr: e.stderr) }
    }

    struct RawMR: Decodable {
        struct User: Decodable { var username: String }
        struct Pipeline: Decodable { var status: String }
        var iid: Int, title: String, web_url: String, author: User, source_branch: String, state: String
        var draft: Bool?, work_in_progress: Bool?, head_pipeline: Pipeline?
    }

    static func pr(_ m: RawMR) -> GitHub.PullRequest {
        var checks = GitHub.PullRequest.Checks()
        switch m.head_pipeline?.status {
        case "success"?: checks.passed = 1
        case "failed"?: checks.failed = 1
        case "running"?, "pending"?, "created"?, "preparing"?, "waiting_for_resource"?: checks.pending = 1
        default: break
        }
        let state = ["opened": "OPEN", "merged": "MERGED", "closed": "CLOSED"][m.state] ?? m.state.uppercased()
        return GitHub.PullRequest(number: m.iid, title: m.title, url: m.web_url, author: m.author.username, headRefName: m.source_branch,
                                  isDraft: m.draft ?? m.work_in_progress ?? false, state: state, reviewDecision: nil, checks: checks)
    }

    public static func mergeRequests(cwd: String, mine: Bool) throws -> [GitHub.PullRequest] {
        try JSONDecoder().decode([RawMR].self, from: api("projects/:id/merge_requests?state=opened&per_page=50" + (mine ? "&scope=created_by_me" : ""), cwd: cwd)).map(pr)
    }

    /// The newest MR from `branch`, with its pipeline's state.
    public static func mergeRequest(cwd: String, branch: String) throws -> GitHub.PullRequest? {
        let b = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch
        guard let m = try JSONDecoder().decode([RawMR].self, from: api("projects/:id/merge_requests?source_branch=\(b)&state=all&per_page=1&order_by=updated_at", cwd: cwd)).first
        else { return nil }
        return pr((try? JSONDecoder().decode(RawMR.self, from: api("projects/:id/merge_requests/\(m.iid)", cwd: cwd))) ?? m)
    }

    struct RawIssue: Decodable {
        struct User: Decodable { var username: String }
        var iid: Int, title: String, description: String?, web_url: String, labels: [String], assignees: [User], state: String
    }

    public static func issues(cwd: String, mine: Bool) throws -> [GitHub.Issue] {
        try JSONDecoder().decode([RawIssue].self, from: api("projects/:id/issues?state=opened&per_page=50" + (mine ? "&scope=assigned_to_me" : ""), cwd: cwd)).map {
            GitHub.Issue(number: $0.iid, title: $0.title, body: $0.description ?? "", url: $0.web_url, labels: $0.labels,
                         assignees: $0.assignees.map(\.username), state: $0.state == "opened" ? "OPEN" : $0.state.uppercased())
        }
    }
}
