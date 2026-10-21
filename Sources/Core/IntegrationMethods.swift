import Foundation

// GitHub / GitLab (through gh / glab), CI runs, Linear, Jira and Bitbucket. Where a method takes a project, it is the
// workspace's (`worktreeId`) or the project's (`repoId`).

/// The PR of the branch checked out in the workspace, or null (cached for two minutes).
public struct GitHubBranchPR: RPCMethod { public static let name = "github.branchPR"; public typealias Result = JSONValue; public var worktreeId: String }
/// "github" | "gitlab" | "bitbucket": what the panels call things.
public struct GitHubForge: RPCMethod { public static let name = "github.forge"; public typealias Result = JSONValue; public var worktreeId: String?, repoId: String? }
public struct GitHubStatus: RPCMethod { public static let name = "github.status"; public typealias Result = JSONValue }
/// `filter`: mine, else open.
public struct GitHubIssues: RPCMethod {
    public static let name = "github.issues"; public typealias Result = JSONValue; public var worktreeId: String?, repoId: String?, filter: String?
}
public struct GitHubChecks: RPCMethod { public static let name = "github.checks"; public typealias Result = JSONValue; public var worktreeId: String?, repoId: String?, pr: Int? }
public struct GitHubFailedLog: RPCMethod {
    public static let name = "github.failedLog"; public typealias Result = JSONValue; public var worktreeId: String?, repoId: String?, runId: Int?
}
public struct GitHubReviewComments: RPCMethod {
    public static let name = "github.reviewComments"; public typealias Result = JSONValue; public var worktreeId: String?, repoId: String?, pr: Int?
}
public struct GitHubProjects: RPCMethod { public static let name = "github.projects"; public typealias Result = JSONValue; public var worktreeId: String?, repoId: String? }
public struct GitHubProjectItems: RPCMethod { public static let name = "github.projectItems"; public typealias Result = JSONValue; public var owner: String, number: Int? }
/// `filter`: mine | review, else open.
public struct GitHubPRs: RPCMethod { public static let name = "github.prs"; public typealias Result = JSONValue; public var worktreeId: String?, repoId: String?, filter: String? }
/// Push, title and body from the commits if not given, open the PR (a draft with `draft`), link it → {url, title}.
public struct GitHubPRCreate: RPCMethod {
    public static let name = "github.pr-create"; public typealias Result = JSONValue
    public var worktreeId: String, title: String?, body: String?, draft: Bool?
}
/// `method`: squash (default) | merge | rebase; `pr`: else the workspace's linked one.
public struct GitHubPRMerge: RPCMethod { public static let name = "github.pr-merge"; public typealias Result = JSONValue; public var worktreeId: String, pr: Int?, method: String? }

/// CI runs of the branch checked out in the workspace → {branch, runs, workflows}.
public struct CIRunsList: RPCMethod { public static let name = "ci.runs"; public typealias Result = JSONValue; public var worktreeId: String }
public struct CIJobs: RPCMethod { public static let name = "ci.jobs"; public typealias Result = JSONValue; public var worktreeId: String, run: Int? }
public struct CILog: RPCMethod { public static let name = "ci.log"; public typealias Result = JSONValue; public var worktreeId: String, job: Int? }
public struct CIRerun: RPCMethod { public static let name = "ci.rerun"; public typealias Result = JSONValue; public var worktreeId: String, run: Int? }
public struct CIDispatch: RPCMethod {
    public static let name = "ci.dispatch"; public typealias Result = JSONValue
    public var worktreeId: String, workflow: String, branch: String, inputs: [String: String]?
}

/// An empty `key` disconnects.
public struct LinearSetKey: RPCMethod { public static let name = "linear.setKey"; public typealias Result = JSONValue; public var key: String }
public struct LinearStatus: RPCMethod { public static let name = "linear.status"; public typealias Result = JSONValue }
/// A team's issues, else mine.
public struct LinearIssues: RPCMethod { public static let name = "linear.issues"; public typealias Result = JSONValue; public var teamId: String? }
public struct LinearTeams: RPCMethod { public static let name = "linear.teams"; public typealias Result = JSONValue }
public struct LinearStates: RPCMethod { public static let name = "linear.states"; public typealias Result = JSONValue; public var teamId: String }
public struct LinearSetState: RPCMethod { public static let name = "linear.setState"; public typealias Result = JSONValue; public var issueId: String, stateId: String }

/// An empty `token` disconnects.
public struct JiraSetCredentials: RPCMethod {
    public static let name = "jira.setCredentials"; public typealias Result = JSONValue; public var site: String, email: String, token: String
}
public struct JiraStatus: RPCMethod { public static let name = "jira.status"; public typealias Result = JSONValue }
/// `jql`, else my open issues.
public struct JiraIssues: RPCMethod { public static let name = "jira.issues"; public typealias Result = JSONValue; public var jql: String? }
public struct JiraTransitions: RPCMethod { public static let name = "jira.transitions"; public typealias Result = JSONValue; public var key: String }
public struct JiraTransitionIssue: RPCMethod { public static let name = "jira.transition"; public typealias Result = JSONValue; public var key: String, id: String }

/// An empty `token` disconnects.
public struct BitbucketSetCredentials: RPCMethod {
    public static let name = "bitbucket.setCredentials"; public typealias Result = JSONValue; public var user: String, token: String
}
public struct BitbucketStatus: RPCMethod { public static let name = "bitbucket.status"; public typealias Result = JSONValue }
