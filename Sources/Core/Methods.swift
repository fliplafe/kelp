import Foundation

// RPC methods declared as types (see `RPCMethod`). The daemon answers them in `Handled` conformances.

/// The running daemon: the app compares it with the kelpd it ships to spot a stale one after an update.
public struct DaemonInfo: RPCMethod {
    public static let name = "daemon.info"
    public struct Result: Codable, Sendable {
        public var path: String, binaryMTime: Double?, pid: Int, liveSessions: Int   // no binaryMTime before 2026-10-19
        public init(path: String, binaryMTime: Double?, pid: Int, liveSessions: Int) {
            self.path = path; self.binaryMTime = binaryMTime; self.pid = pid; self.liveSessions = liveSessions
        }
    }
    public init() {}
}

/// What the app restores (`UIState`): `key` → its value or null; `prefix` → {key: value} for every key that starts with it.
public struct StateGet: RPCMethod {
    public static let name = "state.get"
    public typealias Result = JSONValue
    public var key: String?, prefix: String?
    public init(key: String? = nil, prefix: String? = nil) { self.key = key; self.prefix = prefix }
}

/// A nil (or null) value deletes the key.
public struct StateSet: RPCMethod {
    public static let name = "state.set"
    public typealias Result = Done
    public var key: String, value: JSONValue?
    public init(key: String, value: JSONValue?) { self.key = key; self.value = value }
}

/// An empty title names the session from its task again.
public struct SessionRename: RPCMethod {
    public static let name = "session.rename"
    public typealias Result = Done
    public var id: String, title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// How full the agent's conversation is (Claude Code transcripts); nil when that isn't known.
public struct SessionContextWindow: RPCMethod {
    public static let name = "session.contextWindow"
    public struct Usage: Codable, Sendable, Equatable {
        public var used: Int, window: Int
        public init(used: Int, window: Int) { self.used = used; self.window = window }
    }
    public typealias Result = Usage?
    public var id: String
    public init(id: String) { self.id = id }
}

/// The project's other git worktrees (agents' `.claude/worktrees/…`, older Kelp workspaces) and the disk each takes,
/// biggest first: they grow with every build and nothing in the folder itself shows it.
public struct RepoWorktreeSizes: RPCMethod {
    public static let name = "repo.worktreeSizes"
    public struct Item: Codable, Sendable, Equatable {
        public var path: String, bytes: Int
        /// Nothing uncommitted or untracked, not locked, not one of Kelp's workspaces (those go with Delete Workspace).
        public var removable: Bool
        public init(path: String, bytes: Int, removable: Bool) { self.path = path; self.bytes = bytes; self.removable = removable }
    }
    public typealias Result = [Item]
    public var id: String
    public init(id: String) { self.id = id }
}

/// Removes those of `paths` that are still clean, as `git worktree remove` without --force does (one with changes,
/// untracked files or a lock stays), each with its branch when that branch's commits are on another one too.
public struct RepoRemoveWorktrees: RPCMethod {
    public static let name = "repo.removeWorktrees"
    public struct Result: Codable, Sendable {
        public var removed: [String], kept: [String: String]   // kept: path → why
        public init(removed: [String], kept: [String: String]) { self.removed = removed; self.kept = kept }
    }
    public var id: String, paths: [String]
    public init(id: String, paths: [String]) { self.id = id; self.paths = paths }
}

/// The workspace's name.
public struct WorktreeNote: RPCMethod {
    public static let name = "worktree.note"
    public typealias Result = Done
    public var id: String, note: String
    public init(id: String, note: String) { self.id = id; self.note = note }
}

/// Throws away one hunk of a file's unstaged changes (index `hunk` of its unstaged diff) in workspace `id`. `header`
/// is the hunk's "@@ … @@" line as the caller saw it: if the file changed since, nothing is thrown away.
public struct GitDiscardHunk: RPCMethod {
    public static let name = "git.discardHunk"
    public typealias Result = Done
    public var id: String, file: String, hunk: Int, header: String
    public init(id: String, file: String, hunk: Int, header: String) { self.id = id; self.file = file; self.hunk = hunk; self.header = header }
}
