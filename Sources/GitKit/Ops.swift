import Foundation
import Core

extension Git {
    public static func stage(_ path: String, files: [String]) throws { try run(["add", "--"] + literal(files), cwd: path) }
    public static func unstage(_ path: String, files: [String]) throws { try run(["reset", "-q", "HEAD", "--"] + literal(files), cwd: path) }

    /// Stage (or unstage, `reverse`) a single hunk of `diff` via `git apply --cached`.
    public static func applyHunk(_ path: String, diff: FileDiff, hunk: Int, reverse: Bool) throws {
        try runData(["apply", "--cached", "--recount", "--unidiff-zero"] + (reverse ? ["-R"] : []) + ["-"], cwd: path, stdin: diff.patch(hunk: hunk))
    }

    /// Throw away one unstaged hunk of `diff` (the working tree's version of `git restore -p`): its reverse, applied to the files.
    public static func discardHunk(_ path: String, diff: FileDiff, hunk: Int) throws {
        try runData(["apply", "--recount", "--unidiff-zero", "-R", "-"], cwd: path, stdin: diff.patch(hunk: hunk))
    }

    /// `all`: every change, new files too (what "Commit N Files" counts), not just what's staged. Never with unresolved
    /// conflicts: staging them would commit the conflict markers.
    @discardableResult
    public static func commit(_ path: String, message: String, all: Bool = false, amend: Bool = false) throws -> String {
        if all {
            if try status(path).contains(where: \.conflicted) {
                throw GitError(args: ["commit"], status: 1, stderr: "Resolve the merge conflicts before committing.")
            }
            try run(["add", "-A"], cwd: path)
        }
        try run(["commit", "-q"] + (amend ? ["--amend"] : []) + ["-m", message], cwd: path)
        return try run(["rev-parse", "--short", "HEAD"], cwd: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public struct MergeResult: Sendable, Equatable { public var merged: Bool; public var conflicts: [String] }

    /// A merge is under way in this checkout (MERGE_HEAD exists): its conflicts and resolutions are the user's.
    public static func isMerging(_ path: String) -> Bool {
        (try? run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], cwd: path)) != nil
    }

    /// Merge `branch` into the branch checked out in `target` (usually the main checkout). Aborts on conflict
    /// unless `keepConflicts`, so the caller can show them and hand them to an agent.
    /// `onto`: the branch `target` must have checked out (the base); anything else is refused rather than merged into.
    public static func merge(branch: String, into target: String, onto: String? = nil, keepConflicts: Bool = false) throws -> MergeResult {
        if let onto {
            let here = try currentBranch(target)
            guard here == onto else {
                throw GitError(args: ["merge", branch], status: 1, stderr: "the main checkout is on \(here), not \(onto): switch it back to \(onto) first")
            }
            guard branch != onto else { throw GitError(args: ["merge", branch], status: 1, stderr: "\(branch) is the branch being merged into") }
        }
        // Only a merge started here is ever aborted here: one the user had under way is refused, untouched.
        guard !isMerging(target) else { throw GitError(args: ["merge", branch], status: 1, stderr: "a merge is already in progress in \(target)") }
        do {
            try run(["merge", "--no-edit", rev(branch)], cwd: target)
            return MergeResult(merged: true, conflicts: [])
        } catch {
            let c = try status(target).filter(\.conflicted).map(\.path)
            if c.isEmpty { throw error }
            if !keepConflicts { try run(["merge", "--abort"], cwd: target) }
            return MergeResult(merged: false, conflicts: c)
        }
    }

    public static func log(_ path: String, base: String? = nil, limit: Int = 50) throws -> [(hash: String, subject: String)] {
        let range = try base.map { ["\(try rev($0))..HEAD"] } ?? []
        return try run(["log", "--format=%h%x09%s", "-n\(limit)"] + range, cwd: path)
            .split(separator: "\n").compactMap { l in
                let p = l.split(separator: "\t", maxSplits: 1); return p.count == 2 ? (String(p[0]), String(p[1])) : nil
            }
    }
}
