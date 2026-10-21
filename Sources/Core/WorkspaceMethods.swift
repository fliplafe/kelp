import Foundation

// Projects (repos), their workspaces (worktrees: desks in the project's folder, or git worktrees of their own) and the
// sessions in them. Results are the records (Repo, Worktree, Session) or what's noted, as JSON.

public struct RepoAdd: RPCMethod { public static let name = "repo.add"; public typealias Result = JSONValue; public var path: String, name: String? }
public struct RepoList: RPCMethod { public static let name = "repo.list"; public typealias Result = JSONValue }
/// The scratch project's workspace, made (with a git repo of its own) the first time.
public struct ScratchEnsure: RPCMethod { public static let name = "scratch.ensure"; public typealias Result = JSONValue }
/// The project's folder moved: the project and its desks point at `path`.
public struct RepoRelocate: RPCMethod { public static let name = "repo.relocate"; public typealias Result = JSONValue; public var id: String, path: String }
/// Its workspaces go with it, and their agents stop.
public struct RepoRemove: RPCMethod { public static let name = "repo.remove"; public typealias Result = JSONValue; public var id: String }

public struct WorkspaceCreate: RPCMethod { public static let name = "workspace.create"; public typealias Result = JSONValue; public var repoId: String }
/// A git worktree on a new `branch` from `base`; `tabs`/`setup` false skip .kelp.yaml's. Adds `setupNeedsTrust` or `setupSession`.
public struct WorktreeCreate: RPCMethod {
    public static let name = "worktree.create"; public typealias Result = JSONValue
    public var repoId: String, branch: String?, base: String?, note: String?, tabs: Bool?, setup: Bool?
}
public struct WorktreeList: RPCMethod { public static let name = "worktree.list"; public typealias Result = JSONValue; public var repoId: String?, archived: Bool? }
/// Out of sight with its folder kept: its agents pause.
public struct WorktreeArchive: RPCMethod { public static let name = "worktree.archive"; public typealias Result = JSONValue; public var id: String }
/// `force`: uncommitted changes go too; `dropCommits`: so do commits on no other branch.
public struct WorktreeRemove: RPCMethod {
    public static let name = "worktree.remove"; public typealias Result = JSONValue
    public var id: String, force: Bool?, dropCommits: Bool?
}
public struct WorktreeUnarchive: RPCMethod { public static let name = "worktree.unarchive"; public typealias Result = JSONValue; public var id: String }
/// → how many commits on its branch no other branch or remote has (lost if it's deleted).
public struct WorktreeUnmerged: RPCMethod { public static let name = "worktree.unmerged"; public typealias Result = JSONValue; public var id: String }
public struct WorktreeDirty: RPCMethod { public static let name = "worktree.dirty"; public typealias Result = JSONValue; public var id: String }

public struct SessionList: RPCMethod { public static let name = "session.list"; public typealias Result = JSONValue; public var worktreeId: String? }
/// → {history}: what it printed so far (base64); then `event.output` for this connection.
public struct SessionAttach: RPCMethod { public static let name = "session.attach"; public typealias Result = JSONValue; public var id: String }
public struct SessionDetach: RPCMethod { public static let name = "session.detach"; public typealias Result = JSONValue; public var id: String }
/// The user's keys (`base64`), or `text` as it is.
public struct SessionWrite: RPCMethod { public static let name = "session.write"; public typealias Result = JSONValue; public var id: String, base64: String?, text: String? }
/// `text`, then Enter (unless `enter` is false) a beat later so a TUI takes it as a submit.
public struct SessionSend: RPCMethod {
    public static let name = "session.send"; public typealias Result = JSONValue; public var id: String, text: String, enter: Bool?
    public init(id: String, text: String, enter: Bool? = nil) { self.id = id; self.text = text; self.enter = enter }
}
public struct SessionResize: RPCMethod { public static let name = "session.resize"; public typealias Result = JSONValue; public var id: String, cols: Int?, rows: Int? }
public struct SessionKill: RPCMethod { public static let name = "session.kill"; public typealias Result = JSONValue; public var id: String }
/// `answer`: allow | deny, to the menu on screen → false when there is none.
public struct SessionChoose: RPCMethod { public static let name = "session.choose"; public typealias Result = JSONValue; public var id: String, answer: String }
/// Kept in the login keychain, read when the agent starts. No `value`: deleted.
public struct AgentSetSecret: RPCMethod { public static let name = "agent.setSecret"; public typealias Result = JSONValue; public var agent: String, key: String, value: String? }
public struct PortsList: RPCMethod { public static let name = "ports.list"; public typealias Result = JSONValue; public var worktreeId: String }
/// Only a process one of the workspace's sessions started.
public struct PortsStop: RPCMethod { public static let name = "ports.stop"; public typealias Result = JSONValue; public var worktreeId: String, pid: Int? }
public struct SessionUsage: RPCMethod { public static let name = "session.usage"; public typealias Result = JSONValue }
/// The program a shell runs in the foreground (closing it would stop that), or null.
public struct SessionBusy: RPCMethod { public static let name = "session.busy"; public typealias Result = JSONValue; public var id: String }
/// The last `bytes` it printed, as text.
public struct SessionRead: RPCMethod { public static let name = "session.read"; public typealias Result = JSONValue; public var id: String, bytes: Int? }
/// session.read with room for "Copy Context".
public struct SessionContext: RPCMethod { public static let name = "session.context"; public typealias Result = JSONValue; public var id: String, bytes: Int? }
public struct SessionMarkRead: RPCMethod { public static let name = "session.markRead"; public typealias Result = JSONValue; public var id: String }
public struct SessionMarkUnread: RPCMethod { public static let name = "session.markUnread"; public typealias Result = JSONValue; public var id: String }
/// → {turn, hasBase}: the files its last turn changed and how long it took.
public struct SessionTurn: RPCMethod { public static let name = "session.turn"; public typealias Result = JSONValue; public var id: String }
/// The agent's last message, from its transcript.
public struct SessionLastReply: RPCMethod { public static let name = "session.lastReply"; public typealias Result = JSONValue; public var id: String }

/// Clones `url` into a new folder in `parent` → the added project; progress comes as `event.clone` {id, line}.
public struct RepoClone: RPCMethod { public static let name = "repo.clone"; public typealias Result = JSONValue; public var url: String, parent: String, id: String? }
/// Stops clone `id` (its half-made folder is removed).
public struct RepoCloneCancel: RPCMethod { public static let name = "repo.cloneCancel"; public typealias Result = JSONValue; public var id: String }
