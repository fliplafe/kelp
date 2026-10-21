import Foundation

// Watching instead of asking again and again: a client says what it shows (`watch.start`), the daemon reads it while
// anyone watches — once for all of them — and pushes it as an event when it changed.

/// What can be watched, and what its key names.
public enum WatchTopic: String, Codable, Sendable, CaseIterable {
    /// A workspace's status, branches and line counts (`GitEvent`): read when its files change. Key: worktree id.
    case git
    /// What a workspace's terminals and agents listen on (`PortsEvent`). Key: worktree id.
    case ports
    /// CPU and memory of every live session (`ActivityEvent`). No key.
    case activity
    /// The branch's CI runs (`CIEvent`): read again while one runs. Key: worktree id.
    case ci
    /// The branch's pull request (`PREvent`). Key: worktree id.
    case pr
    /// How full an agent's conversation is (`ContextEvent`): read while it works and when its status changes. Key: session id.
    case context
    /// The agents' plan limits and token use (`LimitsEvent`). No key.
    case limits
}

/// Starts watching for this connection: the last value comes at once (the first when it's read), then each change. Watching
/// what this connection watches already reads it again now (after a push: the CI run it started shows within seconds).
public struct WatchStart: RPCMethod, Hashable {
    public static let name = "watch.start"; public typealias Result = Done
    public var topic: WatchTopic, key: String
    public init(_ topic: WatchTopic, _ key: String = "") { self.topic = topic; self.key = key }
}

/// Stops it; a connection that goes away stops all of its own.
public struct WatchStop: RPCMethod {
    public static let name = "watch.stop"; public typealias Result = Done
    public var topic: WatchTopic, key: String
    public init(_ topic: WatchTopic, _ key: String = "") { self.topic = topic; self.key = key }
}

/// A watched workspace's git, read again after its files changed. `error`: git couldn't say (not a repository…).
public struct GitEvent: RPCEvent, Equatable {
    public static let name = "event.git"
    public var worktree: String
    public var changes: [FileChange]?, branches: BranchInfo?, stats: LineStats?, error: String?
    public init(worktree: String, changes: [FileChange]? = nil, branches: BranchInfo? = nil, stats: LineStats? = nil, error: String? = nil) {
        self.worktree = worktree; self.changes = changes; self.branches = branches; self.stats = stats; self.error = error
    }
}

public struct PortsEvent: RPCEvent, Equatable {
    public static let name = "event.ports"
    public var worktree: String, ports: [PortsList.Port]
    public init(worktree: String, ports: [PortsList.Port]) { self.worktree = worktree; self.ports = ports }
}

public struct ActivityEvent: RPCEvent, Equatable {
    public static let name = "event.activity"
    public var usage: [SessionUsage.Usage]?, error: String?
    public init(usage: [SessionUsage.Usage]? = nil, error: String? = nil) { self.usage = usage; self.error = error }
}

public struct CIEvent: RPCEvent, Equatable {
    public static let name = "event.ci"
    public var worktree: String, result: CIRunsList.Result?, error: String?
    public init(worktree: String, result: CIRunsList.Result? = nil, error: String? = nil) { self.worktree = worktree; self.result = result; self.error = error }
}

public struct PREvent: RPCEvent, Equatable {
    public static let name = "event.pr"
    public var worktree: String, pr: GitHub.PullRequest?
    public init(worktree: String, pr: GitHub.PullRequest?) { self.worktree = worktree; self.pr = pr }
}

/// Nil usage: not known (not Claude Code, ended, just compacted).
public struct ContextEvent: RPCEvent, Equatable {
    public static let name = "event.context"
    public var session: String, usage: SessionContextWindow.Usage?
    public init(session: String, usage: SessionContextWindow.Usage?) { self.session = session; self.usage = usage }
}

public struct LimitsEvent: RPCEvent, Equatable {
    public static let name = "event.limits"
    public var usage: UsageGet.Result
    public init(usage: UsageGet.Result) { self.usage = usage }
}

/// A project or workspace record as it is now, after any change (as `event.session` is for sessions).
extension Repo: RPCEvent { public static let name = "event.repo" }
extension Worktree: RPCEvent { public static let name = "event.worktree" }

/// A project or workspace that's gone (a project takes its workspaces with it).
public struct RemovedEvent: RPCEvent, Equatable {
    public static let name = "event.removed"
    public var repo: String?, worktree: String?
    public init(repo: String? = nil, worktree: String? = nil) { self.repo = repo; self.worktree = worktree }
}
