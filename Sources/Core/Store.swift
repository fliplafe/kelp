import Foundation
import GRDB

/// SQLite persistence for repos, worktrees, sessions and diff comments.
public final class Store: @unchecked Sendable {
    public let db: DatabaseQueue

    public init(path: String? = nil) throws {
        if let path { db = try DatabaseQueue(path: path) } else { db = try DatabaseQueue() }
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "repo") { t in
                t.primaryKey("id", .text); t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique(); t.column("baseBranch", .text).notNull()
                t.column("copyFiles", .jsonText).notNull()
            }
            try db.create(table: "worktree") { t in
                t.primaryKey("id", .text)
                t.column("repoId", .text).notNull().references("repo", onDelete: .cascade)
                t.column("branch", .text).notNull(); t.column("path", .text).notNull()
                t.column("note", .text).notNull(); t.column("archived", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "session") { t in
                t.primaryKey("id", .text); t.column("worktreeId", .text)
                t.column("cwd", .text).notNull(); t.column("command", .text).notNull()
                t.column("agent", .text); t.column("status", .text).notNull()
                t.column("unread", .boolean).notNull(); t.column("pid", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "diffComment") { t in
                t.primaryKey("id", .text); t.column("worktreeId", .text).notNull()
                t.column("file", .text).notNull(); t.column("startLine", .integer).notNull()
                t.column("endLine", .integer).notNull(); t.column("quote", .text).notNull()
                t.column("text", .text).notNull(); t.column("state", .text).notNull()
            }
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "session") { t in
                t.add(column: "title", .text).notNull().defaults(to: "")
                t.add(column: "titleManual", .boolean).notNull().defaults(to: false)
                t.add(column: "summary", .text).notNull().defaults(to: "")
                t.add(column: "argv", .jsonText).notNull().defaults(to: "[]")
            }
        }
        m.registerMigration("v3") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "issue", .text).notNull().defaults(to: "")
                t.add(column: "issueURL", .text).notNull().defaults(to: "")
                t.add(column: "linearIssueId", .text).notNull().defaults(to: "")
                t.add(column: "prNumber", .integer)
                t.add(column: "prURL", .text).notNull().defaults(to: "")
            }
        }
        m.registerMigration("v4") { db in
            try db.alter(table: "worktree") { t in t.add(column: "base", .text).notNull().defaults(to: "") }
        }
        try m.migrate(db)
    }

    public func repos() throws -> [Repo] { try db.read { try Repo.order(Column("name")).fetchAll($0) } }
    public func repo(_ id: String) throws -> Repo? { try db.read { try Repo.fetchOne($0, key: id) } }
    public func worktrees(repo: String? = nil) throws -> [Worktree] {
        try db.read { d in
            var q = Worktree.order(Column("createdAt"))
            if let repo { q = q.filter(Column("repoId") == repo) }
            return try q.fetchAll(d)
        }
    }
    public func worktree(_ id: String) throws -> Worktree? { try db.read { try Worktree.fetchOne($0, key: id) } }
    public func sessions() throws -> [Session] { try db.read { try Session.order(Column("createdAt")).fetchAll($0) } }
    public func session(_ id: String) throws -> Session? { try db.read { try Session.fetchOne($0, key: id) } }
    public func save<R: PersistableRecord>(_ r: R) throws { try db.write { try r.save($0) } }
    public func delete<R: PersistableRecord>(_ r: R) throws { try db.write { _ = try r.delete($0) } }
    public func comments(worktree: String) throws -> [DiffComment] {
        try db.read { try DiffComment.filter(Column("worktreeId") == worktree).fetchAll($0) }
    }
}
