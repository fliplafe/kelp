import Foundation

extension Git {
    public static func stage(_ path: String, files: [String]) throws { try run(["add", "--"] + files, cwd: path) }
    public static func unstage(_ path: String, files: [String]) throws { try run(["reset", "-q", "HEAD", "--"] + files, cwd: path) }

    /// Stage (or unstage, `reverse`) a single hunk of `diff` via `git apply --cached`.
    public static func applyHunk(_ path: String, diff: FileDiff, hunk: Int, reverse: Bool) throws {
        try run(["apply", "--cached", "--recount", "--unidiff-zero"] + (reverse ? ["-R"] : []) + ["-"], cwd: path, stdin: diff.patch(hunk: hunk))
    }

    @discardableResult
    public static func commit(_ path: String, message: String, all: Bool = false, amend: Bool = false) throws -> String {
        try run(["commit", "-q"] + (all ? ["-a"] : []) + (amend ? ["--amend"] : []) + ["-m", message], cwd: path)
        return try run(["rev-parse", "--short", "HEAD"], cwd: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public struct MergeResult: Sendable, Equatable { public var merged: Bool; public var conflicts: [String] }

    /// Merge `branch` into the branch checked out in `target` (usually the main checkout). Aborts on conflict
    /// unless `keepConflicts`, so the caller can show them and hand them to an agent.
    public static func merge(branch: String, into target: String, keepConflicts: Bool = false) throws -> MergeResult {
        do {
            try run(["merge", "--no-edit", branch], cwd: target)
            return MergeResult(merged: true, conflicts: [])
        } catch {
            let c = try status(target).filter(\.conflicted).map(\.path)
            if c.isEmpty { throw error }
            if !keepConflicts { try run(["merge", "--abort"], cwd: target) }
            return MergeResult(merged: false, conflicts: c)
        }
    }

    public static func log(_ path: String, base: String? = nil, limit: Int = 50) throws -> [(hash: String, subject: String)] {
        let range = base.map { ["\($0)..HEAD"] } ?? []
        return try run(["log", "--format=%h%x09%s", "-n\(limit)"] + range, cwd: path)
            .split(separator: "\n").compactMap { l in
                let p = l.split(separator: "\t", maxSplits: 1); return p.count == 2 ? (String(p[0]), String(p[1])) : nil
            }
    }
}
