import Foundation

/// How a session starts: the same optional fields on every method that starts one.
public protocol LaunchOptions {
    var model: String? { get }
    var effort: String? { get }
    var prompt: String? { get }
    var title: String? { get }
    var profile: String? { get }
    /// Type the prompt, don't send it.
    var draft: Bool? { get }
    /// The first local URL it prints opens in the workspace's browser (event.devserver).
    var openURLs: Bool? { get }
    var cols: Int? { get }
    var rows: Int? { get }
}

/// A session in `worktreeId`'s folder, or in `cwd` (which wins): agent `agent`, else the shell command `command`;
/// `tmux`: a terminal attached to that tmux session, started if there is none (see `Tmux`).
public struct SessionCreate: RPCMethod, LaunchOptions {
    public static let name = "session.create"; public typealias Result = JSONValue
    public var cwd: String?, worktreeId: String?, agent: String?, command: String?, tmux: String?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?, openURLs: Bool?, cols: Int?, rows: Int?
}

/// The tmux sessions on the workspace's machine (a remote project's host), the last used first; none while tmux runs
/// no server there.
public struct TmuxList: RPCMethod {
    public static let name = "tmux.list"; public typealias Result = [Tmux.Session]
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}

/// The same command in the same folder, resuming its conversation unless `resume` is false.
public struct SessionRestart: RPCMethod, LaunchOptions {
    public static let name = "session.restart"; public typealias Result = JSONValue
    public var id: String, resume: Bool?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?, openURLs: Bool?, cols: Int?, rows: Int?
}

/// A new agent (`agent`, else the same) in the same workspace, briefed with this one's transcript (`full`: all of it).
public struct SessionHandoff: RPCMethod, LaunchOptions {
    public static let name = "session.handoff"; public typealias Result = JSONValue
    public var id: String, agent: String?, full: Bool?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?, openURLs: Bool?, cols: Int?, rows: Int?
}

/// An issue or task → a branch with its number, a worktree, an agent briefed with its text → {worktree, session, setupNeedsTrust}.
/// (`title` is the issue's: the session's is "ref title".) The brief is typed, not sent, unless `draft` is false: the issue's
/// text is whoever filed it.
public struct TaskFromIssue: RPCMethod {
    public static let name = "task.fromIssue"; public typealias Result = JSONValue
    public var repoId: String, ref: String, title: String, body: String?, url: String?, branch: String?, branchPrefix: String?
    public var linearId: String?, agent: String?, prompt: String?
    public var model: String?, effort: String?, profile: String?, draft: Bool?, openURLs: Bool?, cols: Int?, rows: Int?
}

/// A past conversation (`session`, as history.list gives it) as a live session, in `worktreeId` or its own folder.
public struct HistoryResume: RPCMethod, LaunchOptions {
    public static let name = "history.resume"; public typealias Result = JSONValue
    public var session: JSONValue?, worktreeId: String?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?, openURLs: Bool?, cols: Int?, rows: Int?
}

/// From a running agent's hooks (`kelp hook`): `event`, and what Claude Code's hook payload says.
public struct SessionHook: RPCMethod {
    public static let name = "session.hook"; public typealias Result = JSONValue
    public var id: String, event: String?, transcript: String?, cwd: String?, trigger: String?, notification: JSONValue?
    public var backgroundTasks: [JSONValue]?
    enum CodingKeys: String, CodingKey { case id, event, transcript, cwd, trigger, notification, backgroundTasks = "background_tasks" }
}

/// A summary from the UI (the agent's own last reply), and optionally a better status guess.
public struct SessionAnnotate: RPCMethod {
    public static let name = "session.annotate"; public typealias Result = JSONValue; public var id: String, summary: String?, status: String?
}
/// The prompt for action `name` in workspace `id`, the project's own wording if it has one (and is trusted).
public struct RecipeRender: RPCMethod {
    public static let name = "recipe.render"; public typealias Result = JSONValue; public var id: String, name: String, vars: [String: String]?
}
/// [{id, version, latest}] for the agents on this Mac.
public struct AgentsVersions: RPCMethod { public static let name = "agents.versions"; public typealias Result = JSONValue }
public struct Ping: RPCMethod { public static let name = "ping"; public typealias Result = JSONValue }
public struct DaemonShutdown: RPCMethod { public static let name = "daemon.shutdown"; public typealias Result = JSONValue }
