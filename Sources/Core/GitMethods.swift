import Foundation

// Source control, files and review comments of a workspace (`id` is its worktree id). Results are the shapes GitKit
// returns, as JSON (Core doesn't know GitKit's types).

public struct GitStatus: RPCMethod { public static let name = "git.status"; public typealias Result = JSONValue; public var id: String }
public struct GitBranches: RPCMethod { public static let name = "git.branches"; public typealias Result = JSONValue; public var id: String }
public struct GitLineStats: RPCMethod { public static let name = "git.lineStats"; public typealias Result = JSONValue; public var id: String }
public struct GitPush: RPCMethod { public static let name = "git.push"; public typealias Result = JSONValue; public var id: String }

/// `source`: all (default) | unstaged | staged | branch (against `base`, else the project's) | commit | turn (`session`'s last).
public struct GitDiff: RPCMethod {
    public static let name = "git.diff"; public typealias Result = JSONValue
    public var id: String, source: String?, file: String?, base: String?, commit: String?, session: String?
}
/// Commits on the branch since its base; `all`: the whole history.
public struct GitLog: RPCMethod { public static let name = "git.log"; public typealias Result = JSONValue; public var id: String, all: Bool? }
public struct GitStage: RPCMethod { public static let name = "git.stage"; public typealias Result = JSONValue; public var id: String, files: [String]? }
public struct GitUnstage: RPCMethod { public static let name = "git.unstage"; public typealias Result = JSONValue; public var id: String, files: [String]? }
/// One hunk of `file` staged (or unstaged with `reverse`): the one with `fingerprint`, else `header`, else number `hunk`.
public struct GitHunk: RPCMethod {
    public static let name = "git.hunk"; public typealias Result = JSONValue
    public var id: String, file: String, hunk: Int?, reverse: Bool?, header: String?, fingerprint: String?
}
public struct GitCommit: RPCMethod {
    public static let name = "git.commit"; public typealias Result = JSONValue
    public var id: String, message: String, all: Bool?, amend: Bool?
}
/// The workspace's branch into the project's base branch, in the main checkout → {merged, conflicts}.
public struct GitMerge: RPCMethod { public static let name = "git.merge"; public typealias Result = JSONValue; public var id: String, keepConflicts: Bool? }
public struct GitSwitch: RPCMethod {
    public static let name = "git.switch"; public typealias Result = JSONValue
    public var id: String, branch: String, create: Bool?, remote: Bool?
}
public struct GitGraph: RPCMethod { public static let name = "git.graph"; public typealias Result = JSONValue; public var id: String, limit: Int? }
public struct GitCommitFiles: RPCMethod { public static let name = "git.commitFiles"; public typealias Result = JSONValue; public var id: String, commit: String }
public struct GitDiscard: RPCMethod { public static let name = "git.discard"; public typealias Result = JSONValue; public var id: String, files: [String]? }
/// `op`: pull | push | fetch.
public struct GitRemoteOp: RPCMethod { public static let name = "git.remote"; public typealias Result = JSONValue; public var id: String, op: String }
public struct GitStash: RPCMethod { public static let name = "git.stash"; public typealias Result = JSONValue; public var id: String, pop: Bool? }
/// The file at `path` on its forge at HEAD, lines `start`…`end`.
public struct GitWebURL: RPCMethod { public static let name = "git.webURL"; public typealias Result = JSONValue; public var path: String, start: Int?, end: Int? }

public struct FilesList: RPCMethod { public static let name = "files.list"; public typealias Result = JSONValue; public var id: String }
public struct FilesSearch: RPCMethod {
    public static let name = "files.search"; public typealias Result = JSONValue
    public var id: String, query: String, regex: Bool?, `case`: Bool?
}

/// A review comment on lines `start`…`end` of `file` in workspace `id`.
public struct CommentAdd: RPCMethod {
    public static let name = "comment.add"; public typealias Result = JSONValue
    public var id: String, file: String, start: Int?, end: Int?, quote: String?, text: String
}
public struct CommentList: RPCMethod { public static let name = "comment.list"; public typealias Result = JSONValue; public var id: String }
/// `id`: the comment's. `state`: open | sent | resolved.
public struct CommentSetState: RPCMethod { public static let name = "comment.setState"; public typealias Result = JSONValue; public var id: String, state: String }
/// The workspace's open comments as one message into `session` → how many went.
public struct CommentSend: RPCMethod { public static let name = "comment.send"; public typealias Result = JSONValue; public var id: String, session: String }
