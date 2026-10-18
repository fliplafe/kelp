import Foundation

public struct WorktreeInfo: Sendable, Equatable {
    public var path: String; public var branch: String?; public var head: String
}

extension Git {
    /// Parse `git worktree list --porcelain`.
    public static func parseWorktrees(_ s: String) -> [WorktreeInfo] {
        s.components(separatedBy: "\n\n").compactMap { block in
            var path = "", head = "", branch: String?
            for l in block.split(separator: "\n") {
                if l.hasPrefix("worktree ") { path = String(l.dropFirst(9)) }
                else if l.hasPrefix("HEAD ") { head = String(l.dropFirst(5)) }
                else if l.hasPrefix("branch ") { branch = String(l.dropFirst(7).replacingOccurrences(of: "refs/heads/", with: "")) }
            }
            return path.isEmpty ? nil : WorktreeInfo(path: path, branch: branch, head: head)
        }
    }

    public static func listWorktrees(repo: String) throws -> [WorktreeInfo] {
        parseWorktrees(try run(["worktree", "list", "--porcelain"], cwd: repo))
    }

    /// Slug safe for directory names: "feat/login ui" -> "feat-login-ui".
    public static func slug(_ branch: String) -> String {
        String(branch.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" ? $0 : "-" })
    }

    /// New branch from `base` in a fresh worktree; copies `copyFiles` present in the repo root.
    public static func addWorktree(repo: String, branch: String, base: String, into dir: URL, copyFiles: [String]) throws -> String {
        let path = dir.appendingPathComponent(slug(branch)).path
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run(["worktree", "add", "-b", branch, path, base], cwd: repo)
        let fm = FileManager.default
        for f in copyFiles {
            let src = (repo as NSString).appendingPathComponent(f)
            if fm.fileExists(atPath: src) { try? fm.copyItem(atPath: src, toPath: (path as NSString).appendingPathComponent(f)) }
        }
        return path
    }

    public static func isDirty(_ path: String) throws -> Bool {
        !(try run(["status", "--porcelain"], cwd: path)).isEmpty
    }

    /// Remove worktree and its branch. Refuses dirty worktrees unless `force`.
    public static func removeWorktree(repo: String, path: String, branch: String?, force: Bool) throws {
        if !force, try isDirty(path) {
            throw GitError(args: ["worktree", "remove"], status: 1, stderr: "worktree has uncommitted changes")
        }
        try run(["worktree", "remove", "--force", path], cwd: repo)
        if let branch { try run(["branch", "-D", branch], cwd: repo) }
    }
}
