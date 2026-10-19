import Foundation

public struct DiffLine: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case context, add, del }
    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
}

public struct Hunk: Codable, Sendable, Equatable {
    public var header: String
    public var oldStart: Int, newStart: Int
    public var lines: [DiffLine]
}

public struct FileDiff: Codable, Sendable, Equatable {
    public var path: String
    /// Raw `diff --git` / `---` / `+++` lines, needed to rebuild patches for hunk staging.
    public var header: String
    public var hunks: [Hunk]
    public var binary: Bool
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .add }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .del }.count } }

    /// Patch containing only the given hunk, for `git apply --cached [-R]`.
    public func patch(hunk i: Int) -> String {
        let h = hunks[i]
        var s = header + "\n" + h.header + "\n"
        for l in h.lines {
            s += (l.kind == .add ? "+" : l.kind == .del ? "-" : " ") + l.text + "\n"
        }
        return s
    }
}

/// What a diff is taken against.
public enum DiffSource: Sendable {
    case unstaged                 // worktree vs index
    case staged                   // index vs HEAD
    case allUncommitted           // worktree vs HEAD
    case branch(base: String)     // HEAD vs merge-base(base)
    case commit(String)
}

extension Git {
    public static func parseDiff(_ s: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var header: [String] = [], path = "", binary = false
        var hunks: [Hunk] = []
        var cur: Hunk?
        var o = 0, n = 0
        func flushHunk() { if let c = cur { hunks.append(c); cur = nil } }
        func flushFile() {
            flushHunk()
            if !header.isEmpty { files.append(FileDiff(path: path, header: header.joined(separator: "\n"), hunks: hunks, binary: binary)) }
            header = []; hunks = []; binary = false; path = ""
        }
        for raw in s.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git ") {
                flushFile()
                header = [raw]
                if let r = raw.range(of: " b/", options: .backwards) { path = String(raw[r.upperBound...]) }
            } else if cur == nil && !header.isEmpty && !raw.hasPrefix("@@") {
                if raw.hasPrefix("Binary files") || raw.hasPrefix("GIT binary patch") { binary = true }
                if raw.hasPrefix("+++ b/") { path = String(raw.dropFirst(6)) }
                if raw.hasPrefix("--- a/") && path.isEmpty { path = String(raw.dropFirst(6)) }
                header.append(raw)
            } else if raw.hasPrefix("@@") {
                flushHunk()
                // @@ -a,b +c,d @@
                let nums = raw.split(separator: " ").dropFirst().prefix(2).map { $0.dropFirst().split(separator: ",")[0] }
                o = Int(nums[0]) ?? 1; n = Int(nums[1]) ?? 1
                cur = Hunk(header: raw, oldStart: o, newStart: n, lines: [])
            } else if cur != nil {
                guard let c = raw.first else { continue }   // trailing empty
                let t = String(raw.dropFirst())
                switch c {
                case "+": cur!.lines.append(DiffLine(kind: .add, text: t, oldLine: nil, newLine: n)); n += 1
                case "-": cur!.lines.append(DiffLine(kind: .del, text: t, oldLine: o, newLine: nil)); o += 1
                case " ": cur!.lines.append(DiffLine(kind: .context, text: t, oldLine: o, newLine: n)); o += 1; n += 1
                default: break // "\ No newline at end of file"
                }
            }
        }
        flushFile()
        return files
    }

    public static func diff(_ path: String, source: DiffSource, file: String? = nil) throws -> [FileDiff] {
        var a = ["diff", "--no-color", "--no-ext-diff", "-U3"]
        switch source {
        case .unstaged: break
        case .staged: a.append("--cached")
        case .allUncommitted: a.append("HEAD")
        case .branch(let base): a.append("\(base)...HEAD")
        case .commit(let c): a = ["show", "--no-color", "--format=", "-U3", "-M", "--diff-merges=first-parent", c]
        }
        if let file { a += ["--", file] }
        var diffs = parseDiff(try run(a, cwd: path))
        // Untracked files are invisible to `git diff`; show them as all-added for working-tree sources.
        if case .unstaged = source { diffs += try untrackedDiffs(path, only: file) }
        if case .allUncommitted = source { diffs += try untrackedDiffs(path, only: file) }
        return diffs
    }

    static func untrackedDiffs(_ path: String, only: String?) throws -> [FileDiff] {
        try status(path).filter { $0.untracked && (only == nil || $0.path == only) }.compactMap { f in
            let full = (path as NSString).appendingPathComponent(f.path)
            guard let data = FileManager.default.contents(atPath: full) else { return nil }
            guard let text = String(data: data, encoding: .utf8) else {
                return FileDiff(path: f.path, header: "diff --git a/\(f.path) b/\(f.path)", hunks: [], binary: true)
            }
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            let h = Hunk(header: "@@ -0,0 +1,\(lines.count) @@", oldStart: 0, newStart: 1,
                         lines: lines.enumerated().map { DiffLine(kind: .add, text: $1, oldLine: nil, newLine: $0 + 1) })
            let hdr = "diff --git a/\(f.path) b/\(f.path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(f.path)"
            return FileDiff(path: f.path, header: hdr, hunks: lines.isEmpty ? [] : [h], binary: false)
        }
    }
}
