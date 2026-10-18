import Foundation

/// Flat rows for a diff table: one place builds them so inline and side-by-side stay consistent.
public enum DiffRow: Equatable, Sendable {
    case file(path: String, additions: Int, deletions: Int)
    case hunk(file: Int, index: Int, header: String)
    case gap(lines: Int)                       // unchanged lines between hunks, collapsed
    case line(file: Int, DiffLine)             // inline
    case pair(file: Int, left: DiffLine?, right: DiffLine?)   // side-by-side
    case binary(path: String)
}

public enum DiffRows {
    /// Pair deletions with the additions that follow them; context lines appear on both sides.
    public static func pairs(_ lines: [DiffLine]) -> [(DiffLine?, DiffLine?)] {
        var out: [(DiffLine?, DiffLine?)] = []
        var i = 0
        while i < lines.count {
            if lines[i].kind == .context { out.append((lines[i], lines[i])); i += 1; continue }
            var dels: [DiffLine] = [], adds: [DiffLine] = []
            while i < lines.count, lines[i].kind == .del { dels.append(lines[i]); i += 1 }
            while i < lines.count, lines[i].kind == .add { adds.append(lines[i]); i += 1 }
            for k in 0..<max(dels.count, adds.count) { out.append((k < dels.count ? dels[k] : nil, k < adds.count ? adds[k] : nil)) }
        }
        return out
    }

    public static func build(_ files: [FileDiff], sideBySide: Bool) -> [DiffRow] {
        var rows: [DiffRow] = []
        for (fi, f) in files.enumerated() {
            rows.append(.file(path: f.path, additions: f.additions, deletions: f.deletions))
            if f.binary { rows.append(.binary(path: f.path)); continue }
            var prevEnd: Int?
            for (hi, h) in f.hunks.enumerated() {
                if let p = prevEnd, h.newStart > p { rows.append(.gap(lines: h.newStart - p)) }
                rows.append(.hunk(file: fi, index: hi, header: h.header))
                if sideBySide { for (l, r) in pairs(h.lines) { rows.append(.pair(file: fi, left: l, right: r)) } }
                else { for l in h.lines { rows.append(.line(file: fi, l)) } }
                prevEnd = h.lines.last?.newLine.map { $0 + 1 } ?? h.newStart
            }
        }
        return rows
    }
}
