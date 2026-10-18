import Foundation

/// Who wrote a changed line: lines you edit in Krill's editor are yours; other added lines in a worktree with an agent are the agent's.
/// Limit: tracks edited line numbers only (they drift if lines above move); track per-hunk content hashes if precision matters
@MainActor
enum Attribution {
    private static func key(_ worktree: String, _ file: String) -> String { "attr.\(worktree).\(file)" }

    static func markHuman(worktree: String, file: String, line: Int) {
        let k = key(worktree, file)
        var lines = Set(UserDefaults.standard.array(forKey: k) as? [Int] ?? [])
        if lines.insert(line).inserted { UserDefaults.standard.set(Array(lines), forKey: k) }
    }

    static func humanLines(worktree: String, file: String) -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: key(worktree, file)) as? [Int] ?? [])
    }

    /// Lines you edited go back to "you" — reset when the worktree is committed or archived.
    static func reset(worktree: String) {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("attr.\(worktree).") { UserDefaults.standard.removeObject(forKey: k) }
    }
}
