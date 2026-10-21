import Foundation

// A project's .kelp.yaml commands, remote projects, settings, usage and past conversations.

/// → {scripts, setup, tabs, shared, recipes, issueCommand, digest, trusted, file}: everything trusting it would allow.
public struct ScriptsList: RPCMethod { public static let name = "scripts.list"; public typealias Result = JSONValue; public var worktreeId: String }
/// The project's .kelp.yaml as shown (`digest` from scripts.list) may run. Only from Kelp's window.
public struct ScriptsTrust: RPCMethod { public static let name = "scripts.trust"; public typealias Result = JSONValue; public var worktreeId: String, digest: String? }
/// Runs command `name` (or "setup") in the workspace's folder → the session.
public struct ScriptsRun: RPCMethod { public static let name = "scripts.run"; public typealias Result = JSONValue; public var worktreeId: String, name: String }

/// A project on `host` at `path` (its local folder stands for the one there); `init` makes a plain folder a repository.
public struct RepoAddRemote: RPCMethod { public static let name = "repo.addRemote"; public typealias Result = JSONValue; public var host: String, path: String, `init`: Bool? }
/// A file in a remote project's folder, read on the host.
public struct FilesReadRemote: RPCMethod { public static let name = "files.readRemote"; public typealias Result = JSONValue; public var path: String }
/// Writes `text` to that file on the host → null; → {changed: its text there} instead, unwritten, when it's no longer `base`
/// (an agent there edited it since it was read).
public struct FilesWriteRemote: RPCMethod { public static let name = "files.writeRemote"; public typealias Result = JSONValue; public var path: String, text: String, base: String? }

public struct SettingsGet: RPCMethod { public static let name = "settings.get"; public typealias Result = JSONValue }
/// A null `value` resets the key → all settings.
public struct SettingsSet: RPCMethod { public static let name = "settings.set"; public typealias Result = JSONValue; public var key: String, value: JSONValue? }

/// Per account: Claude's 5-hour block, today and the week; Codex's limits (cached for a minute unless `force`).
public struct UsageGet: RPCMethod { public static let name = "usage.get"; public typealias Result = JSONValue; public var force: Bool? }
/// What Claude Code used over `days`, by day, model and project, priced as the API would.
public struct UsageReport: RPCMethod { public static let name = "usage.report"; public typealias Result = JSONValue; public var days: Int? }
/// Past conversations, newest first; `query` (in `fullText` too), `cwd`, at most `limit`.
public struct HistoryList: RPCMethod {
    public static let name = "history.list"; public typealias Result = JSONValue
    public var query: String?, fullText: Bool?, cwd: String?, limit: Int?
}
