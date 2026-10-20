import Foundation

extension Git {
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
        for f in Array(Set(copyFiles + includedIgnoredFiles(repo: repo))) {
            let src = (repo as NSString).appendingPathComponent(f), dst = (path as NSString).appendingPathComponent(f)
            guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst) else { continue }
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.copyItem(atPath: src, toPath: dst)
        }
        return path
    }

    /// Gitignored files matching `.worktreeinclude` globs (e.g. `.env*`, `config/*.local.json`) — copied into new worktrees.
    public static func includedIgnoredFiles(repo: String) -> [String] {
        guard let text = try? String(contentsOfFile: repo + "/.worktreeinclude", encoding: .utf8) else { return [] }
        let pats = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let ignored = ((try? run(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], cwd: repo)) ?? "").split(separator: "\0").map(String.init)
        return ignored.filter { f in pats.contains { fnmatch($0, f, 0) == 0 || fnmatch($0, (f as NSString).lastPathComponent, 0) == 0 } }
    }

    /// Symlink shared directories (node_modules, .venv…) from the main checkout instead of reinstalling.
    public static func linkShared(_ dirs: [String], repo: String, worktree: String) {
        for d in dirs {
            let src = (repo as NSString).appendingPathComponent(d), dst = (worktree as NSString).appendingPathComponent(d)
            guard FileManager.default.fileExists(atPath: src), !FileManager.default.fileExists(atPath: dst) else { continue }
            try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(atPath: dst, withDestinationPath: src)
        }
    }

    /// The repo's other checkouts, wherever `git worktree add` put them (an agent's `.claude/worktrees/…`, Kelp's own):
    /// `git worktree list` without its first entry, the main checkout.
    public static func linkedWorktrees(_ repo: String) throws -> [(path: String, branch: String?, locked: Bool)] {
        try run(["worktree", "list", "--porcelain"], cwd: repo).components(separatedBy: "\n\n").dropFirst().compactMap { b in
            let lines = b.split(separator: "\n")
            guard let p = lines.first(where: { $0.hasPrefix("worktree ") }) else { return nil }
            let branch = lines.first { $0.hasPrefix("branch refs/heads/") }.map { String($0.dropFirst(18)) }
            return (String(p.dropFirst(9)), branch, lines.contains { $0 == "locked" || $0.hasPrefix("locked ") })
        }
    }

    public static func renameBranch(_ path: String, from old: String, to new: String) throws {
        try run(["branch", "-m", old, new], cwd: path)
    }

    public static func branchExists(_ repo: String, _ b: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/" + b], cwd: repo)) != nil
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
