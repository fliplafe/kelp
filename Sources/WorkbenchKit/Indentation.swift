import Foundation

/// How a file is indented, as the editor's status bar says it: tabs, or spaces in steps of `n`.
public enum Indentation: Equatable, Sendable {
    case tabs, spaces(Int)

    /// Read from the file's first lines: tabs if most indented lines start with one; else the widest step (8, 4, 3, 2)
    /// that nine in ten of the indented lines are a multiple of. Nil when nothing is indented.
    public static func detect(_ text: String) -> Indentation? {
        var tabs = 0, widths: [Int] = [], lines = 0
        // Bytes, stopping at the 2000th line: splitting all of a 5 MB file into Characters took 80 ms of main thread.
        let b = text.utf8
        var i = b.startIndex
        while i < b.endIndex, lines < 2000 {
            let end = b[i...].firstIndex { (10...13).contains($0) } ?? b.endIndex   // \n, \r (\r\n leaves an empty line), VT, FF
            let line = b[i..<end]
            i = end < b.endIndex ? b.index(after: end) : end
            guard !line.isEmpty else { continue }
            lines += 1
            if line.first == 9 { tabs += 1; continue }
            let n = line.prefix { $0 == 32 }.count
            if n > 0, n < line.count { widths.append(n) }
        }
        if tabs > widths.count { return .tabs }
        guard !widths.isEmpty else { return nil }
        let step = [8, 4, 3, 2].first { s in Double(widths.filter { $0 % s == 0 }.count) >= 0.9 * Double(widths.count) } ?? 1
        return .spaces(step)
    }
}
