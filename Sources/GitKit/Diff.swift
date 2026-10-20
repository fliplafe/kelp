import Foundation

public struct DiffLine: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case context, add, del }
    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
    /// The file's last line, with no newline after it (git's "\ No newline at end of file").
    public var noNewline: Bool?
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
    /// The file isn't UTF-8: its text was read byte for byte (Latin-1), and patches go back the same way.
    public var latin1: Bool?
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .add }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .del }.count } }

    /// Patch containing only the given hunk, for `git apply --cached [-R]`, in the file's own bytes.
    public func patch(hunk i: Int) -> Data {
        var s = header + "\n" + hunks[i].header + "\n"
        for l in hunks[i].lines {
            s += (l.kind == .add ? "+" : l.kind == .del ? "-" : " ") + l.text + "\n"
            if l.noNewline == true { s += "\\ No newline at end of file\n" }
        }
        return latin1 == true ? Data(s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }) : Data(s.utf8)
    }
}

/// What a diff is taken against.
public enum DiffSource: Sendable {
    case unstaged                 // worktree vs index
    case staged                   // index vs HEAD
    case allUncommitted           // worktree vs HEAD
    case branch(base: String)     // HEAD vs merge-base(base)
    case commit(String)
    case since(tree: String)      // the working tree now vs a snapshot taken earlier (`snapshotTree`)
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
                // `a/x b/x`, or `"a/x" "b/x"` when a name has quotes, backslashes or control characters (git escapes those).
                if let r = raw.range(of: raw.hasSuffix("\"") ? " \"b/" : " b/", options: .backwards),
                   let p = headerPath(raw[raw.index(after: r.lowerBound)...]) { path = p }
            } else if cur == nil && !header.isEmpty && !raw.hasPrefix("@@") {
                if raw.hasPrefix("Binary files") || raw.hasPrefix("GIT binary patch") { binary = true }
                if raw.hasPrefix("+++ "), let p = headerPath(raw.dropFirst(4)) { path = p }
                if raw.hasPrefix("--- ") && path.isEmpty, let p = headerPath(raw.dropFirst(4)) { path = p }
                header.append(raw)
            } else if raw.hasPrefix("@@") {
                flushHunk()
                // @@ -a,b +c,d @@
                let nums = raw.split(separator: " ").dropFirst().prefix(2).map { $0.dropFirst().split(separator: ",").first.flatMap { Int($0) } }
                o = nums.first.flatMap { $0 } ?? 1; n = nums.dropFirst().first.flatMap { $0 } ?? 1
                cur = Hunk(header: raw, oldStart: o, newStart: n, lines: [])
            } else if cur != nil {
                guard let c = raw.first else { continue }   // trailing empty
                let t = String(raw.dropFirst())
                switch c {
                case "+": cur?.lines.append(DiffLine(kind: .add, text: t, oldLine: nil, newLine: n)); n += 1
                case "-": cur?.lines.append(DiffLine(kind: .del, text: t, oldLine: o, newLine: nil)); o += 1
                case " ": cur?.lines.append(DiffLine(kind: .context, text: t, oldLine: o, newLine: n)); o += 1; n += 1
                case "\\": if let last = cur?.lines.indices.last { cur?.lines[last].noNewline = true }   // "\ No newline at end of file"
                default: break
                }
            }
        }
        flushFile()
        return files
    }

    /// Each file of git's diff output decoded on its own: as UTF-8, or byte for byte (Latin-1) when it isn't, so a patch
    /// built back from it applies (a lossy decode would put U+FFFD where the file has other bytes).
    public static func parseDiff(_ d: Data) -> [FileDiff] {
        if let s = String(data: d, encoding: .utf8) { return parseDiff(s) }
        let mark = Data("\ndiff --git ".utf8)
        var starts = [d.startIndex], from = d.startIndex
        while let r = d.range(of: mark, in: from..<d.endIndex) { starts.append(r.lowerBound + 1); from = r.upperBound }
        return zip(starts, starts.dropFirst() + [d.endIndex]).flatMap { a, b -> [FileDiff] in
            let chunk = d[a..<b]
            if let s = String(data: chunk, encoding: .utf8) { return parseDiff(s) }
            return parseDiff(String(data: chunk, encoding: .isoLatin1) ?? "").map { var f = $0; f.latin1 = true; return f }
        }
    }

    /// `a/x` or `b/x` from a diff header, unquoted; nil for `/dev/null`.
    static func headerPath(_ s: Substring) -> String? {
        var s = String(s)
        if s.hasSuffix("\t") { s.removeLast() }   // git ends a ---/+++ name that has a space with a tab
        s = unquoted(s)
        return s.hasPrefix("a/") || s.hasPrefix("b/") ? String(s.dropFirst(2)) : nil
    }

    /// A name git wrote C-quoted (`"x\"y"`, `"\303\244"`) as it is.
    static func unquoted(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        let b = Array(s.utf8.dropFirst().dropLast())
        let escapes: [UInt8: UInt8] = [UInt8(ascii: "n"): 10, UInt8(ascii: "t"): 9, UInt8(ascii: "r"): 13, UInt8(ascii: "a"): 7,
                                       UInt8(ascii: "b"): 8, UInt8(ascii: "f"): 12, UInt8(ascii: "v"): 11]
        var out: [UInt8] = [], i = 0
        while i < b.count {
            guard b[i] == UInt8(ascii: "\\"), i + 1 < b.count else { out.append(b[i]); i += 1; continue }
            if i + 3 < b.count, let o = String(bytes: b[(i + 1)...(i + 3)], encoding: .ascii), let v = UInt8(o, radix: 8) { out.append(v); i += 4; continue }
            out.append(escapes[b[i + 1]] ?? b[i + 1]); i += 2
        }
        return String(bytes: out, encoding: .utf8) ?? s
    }

    public static func diff(_ path: String, source: DiffSource, file: String? = nil) throws -> [FileDiff] {
        // Fixed prefixes and no external tool: a user's diff.noprefix / diff.mnemonicPrefix / diff.external don't change the output.
        let common = ["--no-color", "--no-ext-diff", "-U3", "--src-prefix=a/", "--dst-prefix=b/"]
        var a = ["diff"] + common
        switch source {
        case .unstaged: break
        case .staged: a.append("--cached")
        case .allUncommitted: a.append("HEAD")
        case .branch(let base): a.append("\(base)...HEAD")
        case .commit(let c): a = ["show", "--format=", "-M", "--diff-merges=first-parent"] + common + [c]
        case .since(let tree): a += [tree, try snapshotTree(path)]   // two trees: new files included, nothing staged
        }
        if let file { a += ["--"] + literal([file]) }
        var diffs = parseDiff(try runData(a, cwd: path))
        // Untracked files are invisible to `git diff`; show them as all-added for working-tree sources.
        if case .unstaged = source { diffs += try untrackedDiffs(path, only: file) }
        if case .allUncommitted = source { diffs += try untrackedDiffs(path, only: file) }
        return diffs
    }

    static func untrackedDiffs(_ path: String, only: String?) throws -> [FileDiff] {
        try status(path, only: only).filter { $0.untracked && (only == nil || $0.path == only) }.compactMap { f in
            let full = (path as NSString).appendingPathComponent(f.path)
            let hdr = "diff --git a/\(f.path) b/\(f.path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(f.path)"
            let asBinary = FileDiff(path: f.path, header: hdr, hunks: [], binary: true)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? Int else { return nil }
            guard size <= 1_000_000 else { return asBinary }   // a log, a dataset, a folder that should be ignored: not read
            guard let data = FileManager.default.contents(atPath: full) else { return nil }
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return asBinary }
            var lines = text.components(separatedBy: "\n")
            let lastNewline = lines.last == ""
            if lastNewline { lines.removeLast() }
            var added = lines.enumerated().map { DiffLine(kind: .add, text: $1, oldLine: nil, newLine: $0 + 1) }
            if !lastNewline, !added.isEmpty { added[added.count - 1].noNewline = true }
            let h = Hunk(header: "@@ -0,0 +1,\(lines.count) @@", oldStart: 0, newStart: 1, lines: added)
            return FileDiff(path: f.path, header: hdr, hunks: lines.isEmpty ? [] : [h], binary: false)
        }
    }
}
