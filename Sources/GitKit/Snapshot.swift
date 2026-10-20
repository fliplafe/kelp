import Foundation

extension Git {
    /// The working tree as it is now (tracked and new files, .gitignore respected) written as a tree object, so a
    /// later diff shows exactly what changed since. A copy of the index is updated, never the real one; files whose
    /// stat didn't change aren't hashed again.
    public static func snapshotTree(_ cwd: String) throws -> String {
        let rel = try run(["rev-parse", "--git-path", "index"], cwd: cwd).trimmingCharacters(in: .whitespacesAndNewlines)
        let real = URL(fileURLWithPath: rel, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).path
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-index-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: copy) }
        if FileManager.default.fileExists(atPath: real) { try FileManager.default.copyItem(atPath: real, toPath: copy) }
        try run(["add", "-A"], cwd: cwd, env: ["GIT_INDEX_FILE": copy])
        return try run(["write-tree"], cwd: cwd, env: ["GIT_INDEX_FILE": copy]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Files changed since a snapshot, with line counts ("Changed 3 files +40 −5" after an agent's turn).
    public static func changesSince(tree: String, cwd: String) throws -> [(path: String, added: Int, removed: Int)] {
        let now = try snapshotTree(cwd)
        guard now != tree else { return [] }
        return try run(["diff", "--numstat", "--no-renames", tree, now], cwd: cwd).split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2)
            guard f.count == 3 else { return nil }
            return (String(f[2]), Int(f[0]) ?? 0, Int(f[1]) ?? 0)
        }
    }
}
