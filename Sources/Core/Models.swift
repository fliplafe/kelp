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
    public init(id: String = UUID().uuidString, repoId: String, branch: String, path: String, note: String = "", archived: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.repoId = repoId; self.branch = branch; self.path = path
        self.note = note; self.archived = archived; self.createdAt = createdAt
    }
    public static let databaseTableName = "worktree"
}

public enum AgentStatus: String, Codable, Sendable {
    case idle, working, waiting, done, exited
}

public struct Session: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String
    public var worktreeId: String?
    public var cwd: String
    public var command: String
    public var agent: String?
    public var status: AgentStatus
    public var unread: Bool
    public var pid: Int32
    public var createdAt: Date
    public init(id: String = UUID().uuidString, worktreeId: String? = nil, cwd: String, command: String, agent: String? = nil, status: AgentStatus = .idle, unread: Bool = false, pid: Int32 = 0, createdAt: Date = Date()) {
        self.id = id; self.worktreeId = worktreeId; self.cwd = cwd; self.command = command; self.agent = agent
        self.status = status; self.unread = unread; self.pid = pid; self.createdAt = createdAt
    }
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
