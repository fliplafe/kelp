import Foundation
import Core

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
        // Fixed prefixes and no external tool or textconv: a user's diff.noprefix / diff.mnemonicPrefix / diff.external don't
        // change the output, and a repo's own config can't run a program on every diff shown (nor give a patch that won't apply).
        let common = ["--no-color", "--no-ext-diff", "--no-textconv", "-U3", "--src-prefix=a/", "--dst-prefix=b/"]
        var a = ["diff"] + common
        switch source {
        case .unstaged: break
        case .staged: a.append("--cached")
        case .allUncommitted: a.append("HEAD")
        case .branch(let base): a.append("\(try rev(base))...HEAD")
        case .commit(let c): a = ["show", "--format=", "-M", "--diff-merges=first-parent"] + common + [try rev(c)]
        case .since(let tree): a += [try rev(tree), try snapshotTree(path)]   // two trees: new files included, nothing staged
        }
        if let file { a += ["--"] + literal([file]) }
        var diffs = parseDiff(try runData(a, cwd: path))
        // Untracked files are invisible to `git diff`; show them as all-added for working-tree sources.
        if case .unstaged = source { diffs += try untrackedDiffs(path, only: file) }
        if case .allUncommitted = source { diffs += try untrackedDiffs(path, only: file) }
        return diffs
    }

    static func untrackedDiffs(_ path: String, only: String?) throws -> [FileDiff] {
        let remote = RemoteHost.of(path)
        let files = try status(path, only: only).filter { $0.untracked && (only == nil || $0.path == only) }
        // On the host: all of them in one round trip, each at most a byte past the limit (the folder here is a marker).
        let there = remote.map { r in (try? untrackedOnHost(r, files.map(\.path))) ?? [:] } ?? [:]
        return files.compactMap { f in
            let full = (path as NSString).appendingPathComponent(f.path)
            let mode = FileManager.default.isExecutableFile(atPath: full) ? "100755" : "100644"   // staged as it is: a script stays runnable
            let hdr = "diff --git a/\(f.path) b/\(f.path)\nnew file mode \(mode)\n--- /dev/null\n+++ b/\(f.path)"
            let asBinary = FileDiff(path: f.path, header: hdr, hunks: [], binary: true)
            if remote != nil {
                guard let data = there[f.path], data.count <= 1_000_000 else { return asBinary }
                return added(data, f.path, hdr) ?? asBinary
            }
            // A symlink is shown as git stores it, its target path; following it could read /dev/zero or a huge file.
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: full) {
                let h = Hunk(header: "@@ -0,0 +1 @@", oldStart: 0, newStart: 1, lines: [DiffLine(kind: .add, text: target, oldLine: nil, newLine: 1, noNewline: true)])
                return FileDiff(path: f.path, header: hdr.replacingOccurrences(of: "new file mode \(mode)", with: "new file mode 120000"), hunks: [h], binary: false)
            }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? Int else { return nil }
            guard size <= 1_000_000 else { return asBinary }   // a log, a dataset, a folder that should be ignored: not read
            guard let data = FileManager.default.contents(atPath: full) else { return nil }
            return added(data, f.path, hdr) ?? asBinary
        }
    }

    /// Untracked files on a remote project's host, one ssh round trip per 200 (a command line has a length limit): each
    /// its first 1 MB and a byte; one that isn't a regular file or can't be read is left out (shown as binary).
    static func untrackedOnHost(_ r: RemoteHost, _ paths: [String]) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for start in stride(from: 0, to: paths.count, by: 200) {
            let chunk = paths[start..<min(start + 200, paths.count)]
            let names = chunk.map { RemoteHost.quote(r.path + "/" + $0) }.joined(separator: " ")
            // Each file as a line with its length (-1: not read) and then that many bytes.
            let script = "t=$(mktemp) || exit 1; for f in \(names); do if [ -f \"$f\" ] && head -c 1000001 -- \"$f\" > \"$t\" 2>/dev/null; "
                + "then echo $(wc -c < \"$t\"); cat \"$t\"; else echo -1; fi; done; rm -f \"$t\""
            var rest = try r.run(script)[...]
            for p in chunk {
                guard let nl = rest.firstIndex(of: 0x0A), let n = Int(String(decoding: rest[..<nl], as: UTF8.self)) else { break }
                rest = rest[(nl + 1)...]
                guard n >= 0, rest.count >= n else { continue }
                out[p] = Data(rest.prefix(n)); rest = rest.dropFirst(n)
            }
        }
        return out
    }

    /// A new file's text as one added hunk; nil when it isn't text.
    private static func added(_ data: Data, _ path: String, _ hdr: String) -> FileDiff? {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        let lastNewline = lines.last == ""
        if lastNewline { lines.removeLast() }
        var added = lines.enumerated().map { DiffLine(kind: .add, text: $1, oldLine: nil, newLine: $0 + 1) }
        if !lastNewline, !added.isEmpty { added[added.count - 1].noNewline = true }
        let h = Hunk(header: "@@ -0,0 +1,\(lines.count) @@", oldStart: 0, newStart: 1, lines: added)
        return FileDiff(path: path, header: hdr, hunks: lines.isEmpty ? [] : [h], binary: false)
    }
}
