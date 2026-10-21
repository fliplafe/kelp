import Foundation
import GRDB

public struct Repo: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var baseBranch: String
    /// Glob-ish file names copied from the repo into each new worktree (e.g. ".env").
    public var copyFiles: [String]
    public init(id: String = UUID().uuidString, name: String, path: String, baseBranch: String = "main", copyFiles: [String] = [".env", ".env.local"]) {
        self.id = id; self.name = name; self.path = path; self.baseBranch = baseBranch; self.copyFiles = copyFiles
    }
    public static let databaseTableName = "repo"
}

public struct Worktree: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String
    public var repoId: String
    public var branch: String
    public var path: String
    public var note: String
    public var archived: Bool
    public var createdAt: Date
    /// Links to the task it came from and the PR it became: "#123" / "ENG-123".
    public var issue: String
    public var issueURL: String
    public var linearIssueId: String
    public var prNumber: Int?
    public var prURL: String
    /// Branch this one was cut from; when it isn't the repo's base the worktree is part of a PR stack.
    public var base: String
    public init(id: String = UUID().uuidString, repoId: String, branch: String, path: String, note: String = "", archived: Bool = false, createdAt: Date = Date(),
                issue: String = "", issueURL: String = "", linearIssueId: String = "", prNumber: Int? = nil, prURL: String = "", base: String = "") {
        self.base = base
        self.id = id; self.repoId = repoId; self.branch = branch; self.path = path
        self.note = note; self.archived = archived; self.createdAt = createdAt
        self.issue = issue; self.issueURL = issueURL; self.linearIssueId = linearIssueId; self.prNumber = prNumber; self.prURL = prURL
    }
    public static let databaseTableName = "worktree"
}

public enum AgentStatus: String, Codable, Sendable {
    case idle, working, waiting, done, exited
    /// Process stopped to save memory; resumes its conversation when opened again.
    case hibernated
    /// The agent says its turn failed (OSC 7501 "error"); it stays so until the next turn.
    case error
    public var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .waiting: "Needs you"
        case .done: "Done"
        case .exited: "Exited"
        case .hibernated: "Paused"
        case .error: "Failed"
        }
    }
}

public struct Session: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String
    public var worktreeId: String?
    public var cwd: String
    public var command: String
    public var agent: String?
    public var status: AgentStatus { didSet { if status != oldValue { statusAt = Date() } } }
    /// When `status` last changed ("working for 4m", "done 2h ago"); nil for sessions from before it was kept.
    public var statusAt: Date?
    public var unread: Bool
    public var pid: Int32
    public var createdAt: Date
    /// Tab title (from the first prompt, or set by hand — a manual name wins).
    public var title: String
    public var titleManual: Bool
    /// One-line summary of what the agent did / is asking (local model or hooks).
    public var summary: String
    /// Launch options, kept so "Restart" reproduces the session.
    public var argv: [String]
    /// Where the agent works when it left `cwd` (Claude Code going into its `.claude/worktrees/…`), from its hooks; nil
    /// while it works in `cwd`. Paths it prints and its last turn's changes are read there; a restart still starts in `cwd`.
    public var workDir: String?
    /// How far what runs in it got, 0–100, when it says (OSC 7501's `progress`, `kelp report`, ConEmu's OSC 9;4).
    public var progress: Int?
    /// How its program ended: the exit code, or 128 + the signal that stopped it; nil while it runs.
    public var exitCode: Int?
    /// The account profile it started with (Settings › Accounts); nil: the agent's own default login. Kept so a woken or
    /// restarted session comes back on the same account.
    public var profile: String?
    public init(id: String = UUID().uuidString, worktreeId: String? = nil, cwd: String, command: String, agent: String? = nil,
                status: AgentStatus = .idle, unread: Bool = false, pid: Int32 = 0, createdAt: Date = Date(),
                title: String = "", titleManual: Bool = false, summary: String = "", argv: [String] = []) {
        self.id = id; self.worktreeId = worktreeId; self.cwd = cwd; self.command = command; self.agent = agent
        self.status = status; self.statusAt = createdAt; self.unread = unread; self.pid = pid; self.createdAt = createdAt
        self.title = title; self.titleManual = titleManual; self.summary = summary; self.argv = argv
    }
    public var displayTitle: String { title.isEmpty ? (agent ?? "shell") : title }
    /// The folder the agent works in now.
    public var currentDir: String { workDir ?? cwd }
    public static let databaseTableName = "session"
}

public struct DiffComment: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public enum State: String, Codable, Sendable { case open, sent, resolved }
    public var id: String
    public var worktreeId: String
    public var file: String
    public var startLine: Int
    public var endLine: Int
    public var quote: String
    public var text: String
    public var state: State
    public init(id: String = UUID().uuidString, worktreeId: String, file: String, startLine: Int, endLine: Int, quote: String, text: String, state: State = .open) {
        self.id = id; self.worktreeId = worktreeId; self.file = file; self.startLine = startLine
        self.endLine = endLine; self.quote = quote; self.text = text; self.state = state
    }
    public static let databaseTableName = "diffComment"
}

extension Worktree {
    /// The name people see: their own, or the branch.
    public var displayName: String { note.isEmpty ? branch : note }
}
