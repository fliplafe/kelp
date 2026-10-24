import Foundation
import Core

extension Git {
    /// Slug safe for directory names: "feat/login ui" -> "feat-login-ui".
    public static func slug(_ branch: String) -> String {
        String(branch.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" ? $0 : "-" })
    }

    /// New branch from `base` in a fresh worktree; copies `copyFiles` present in the repo root.
    public static func addWorktree(repo: String, branch: String, base: String, into dir: URL, copyFiles: [String], remotes: Remotes = .none) throws -> String {
        // "feat/a" and "feat-a" make one slug: the second gets "-2" rather than a confusing "already exists" from git.
        var path = dir.appendingPathComponent(slug(branch)).path, n = 2
        while FileManager.default.fileExists(atPath: path) { path = dir.appendingPathComponent("\(slug(branch))-\(n)").path; n += 1 }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run(["worktree", "add", "-b", rev(branch), path, rev(base)], cwd: repo, remotes: remotes)
        let fm = FileManager.default
        for f in Array(Set(copyFiles + includedIgnoredFiles(repo: repo, remotes: remotes))) {
            let src = (repo as NSString).appendingPathComponent(f), dst = (path as NSString).appendingPathComponent(f)
            guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst), staysInside(dst, path) else { continue }
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.copyItem(atPath: src, toPath: dst)
        }
        return path
    }

    /// Gitignored files matching `.worktreeinclude` globs (e.g. `.env*`, `config/*.local.json`) — copied into new worktrees.
    public static func includedIgnoredFiles(repo: String, remotes: Remotes = .none) -> [String] {
        guard let text = try? String(contentsOfFile: repo + "/.worktreeinclude", encoding: .utf8) else { return [] }
        let pats = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let ignored = ((try? run(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], cwd: repo, remotes: remotes)) ?? "")
            .split(separator: "\0").map(String.init)
        return ignored.filter { f in pats.contains { fnmatch($0, f, 0) == 0 || fnmatch($0, (f as NSString).lastPathComponent, 0) == 0 } }
    }

    /// `dst` is still in `root` once symlinks are followed: a folder the branch commits as a link (`conf -> ~/x`) would
    /// take the copy (the user's ignored `.env`), or the folders made for it, out of the worktree.
    static func staysInside(_ dst: String, _ root: String) -> Bool {
        var folder = (dst as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: folder), folder.count > 1 { folder = (folder as NSString).deletingLastPathComponent }
        let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path, inside = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        return real == inside || real.hasPrefix(inside + "/")
    }

    /// Symlink shared directories (node_modules, .venv…) from the main checkout instead of reinstalling.
    public static func linkShared(_ dirs: [String], repo: String, worktree: String) {
        // Only paths inside the project: "/etc", "../x" or "a/../../b" would link (or create folders) outside it.
        for d in dirs where !d.hasPrefix("/") && !d.hasPrefix("~") && !d.split(separator: "/").contains("..") {
            let src = (repo as NSString).appendingPathComponent(d), dst = (worktree as NSString).appendingPathComponent(d)
            guard FileManager.default.fileExists(atPath: src), !FileManager.default.fileExists(atPath: dst), staysInside(dst, worktree) else { continue }
            try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(atPath: dst, withDestinationPath: src)
        }
    }

    /// The repo's other checkouts, wherever `git worktree add` put them (an agent's `.claude/worktrees/…`, Kelp's own):
    /// `git worktree list` without its first entry, the main checkout.
    public static func linkedWorktrees(_ repo: String, remotes: Remotes = .none) throws -> [(path: String, branch: String?, locked: Bool)] {
        try run(["worktree", "list", "--porcelain"], cwd: repo, remotes: remotes).components(separatedBy: "\n\n").dropFirst().compactMap { b in
            let lines = b.split(separator: "\n")
            guard let p = lines.first(where: { $0.hasPrefix("worktree ") }) else { return nil }
            let branch = lines.first { $0.hasPrefix("branch refs/heads/") }.map { String($0.dropFirst(18)) }.flatMap { Git.isRevision($0) ? $0 : nil }
            return (String(p.dropFirst(9)), branch, lines.contains { $0 == "locked" || $0.hasPrefix("locked ") })
        }
    }

    public static func renameBranch(_ path: String, from old: String, to new: String, remotes: Remotes = .none) throws {
        try run(["branch", "-m", rev(old), rev(new)], cwd: path, remotes: remotes)
    }

    public static func branchExists(_ repo: String, _ b: String, remotes: Remotes = .none) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/" + b], cwd: repo, remotes: remotes)) != nil
    }

    public static func isDirty(_ path: String, remotes: Remotes = .none) throws -> Bool {
        !(try run(["status", "--porcelain"], cwd: path, remotes: remotes)).isEmpty
    }

    /// Remove worktree and its branch. Refuses dirty worktrees unless `force`, and a branch with commits that are on no
    /// other branch or remote unless `force` or `dropCommits` (they'd be gone for good). Both checks come first: on
    /// refusal nothing has been removed. A local folder goes to the Trash: what git doesn't see (ignored .env files, a
    /// local database, submodules' own work) isn't checked above, and `worktree remove --force` would delete it for good.
    public static func removeWorktree(repo: String, path: String, branch: String?, force: Bool, dropCommits: Bool = false, remotes: Remotes = .none) throws {
        try checkRemovable(repo: repo, path: path, branch: branch, force: force, dropCommits: dropCommits, remotes: remotes)
        if remotes.of(path) == nil, FileManager.default.fileExists(atPath: path) {
            // Only a folder git lists as this repo's worktree goes to the Trash, whatever the record says.
            let real = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            guard let entry = try linkedWorktrees(repo).first(where: { real($0.path) == real(path) }) else {
                throw GitError(args: ["worktree", "remove"], status: 1, stderr: "\(path) is not a worktree of this repository")
            }
            // Locked (`git worktree lock`: kept on purpose): git wouldn't remove its record, so the folder stays too.
            guard !entry.locked else { throw GitError(args: ["worktree", "remove"], status: 1, stderr: "\(path) is locked (git worktree unlock)") }
            try Trash.move(URL(fileURLWithPath: path))
        }
        // Its record only: `worktree prune` would also drop worktrees whose folder is just away (an unmounted disk).
        try run(["worktree", "remove", "--force", path], cwd: repo, remotes: remotes)
        if let branch { try run(["branch", "-D", rev(branch)], cwd: repo, remotes: remotes) }
    }

    /// What `removeWorktree` would refuse, without removing anything.
    public static func checkRemovable(repo: String, path: String, branch: String?, force: Bool, dropCommits: Bool = false, remotes: Remotes = .none) throws {
        if !force, try isDirty(path, remotes: remotes) {
            throw GitError(args: ["worktree", "remove"], status: 1, stderr: "worktree has uncommitted changes")
        }
        // `force` is about uncommitted changes; commits are lost only when asked for by name (dropCommits).
        if let branch, !dropCommits, case let n = try onlyOnBranch(repo: repo, branch, remotes: remotes), n > 0 {
            throw GitError(args: ["branch", "-D", branch], status: 1,
                           stderr: "\(branch) has \(n) commit\(n == 1 ? "" : "s") that aren't on any other branch or remote")
        }
        // Commits made on a detached HEAD belong to no branch at all: removing the folder would leave them to `git gc`.
        if !dropCommits, FileManager.default.fileExists(atPath: path),
           case let n = Int((try? run(["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes"], cwd: path, remotes: remotes))?   // no commits yet: 0
               .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0, n > 0 {
            throw GitError(args: ["worktree", "remove"], status: 1,
                           stderr: "This workspace has \(n) commit\(n == 1 ? "" : "s") on no branch (a detached HEAD). Create a branch for them first.")
        }
    }

    /// Commits on `branch` that no other local branch and no remote branch has: what deleting it would lose.
    public static func onlyOnBranch(repo: String, _ branch: String, remotes: Remotes = .none) throws -> Int {
        // --exclude before --branches takes the branch's name without refs/heads/ (with it, nothing is excluded).
        let out = try run(["rev-list", "--count", "refs/heads/" + branch, "--not", "--exclude=" + branch, "--branches", "--remotes"],
                          cwd: repo, remotes: remotes)
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
