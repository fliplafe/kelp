import Foundation

/// How a file is indented, as the editor's status bar says it: tabs, or spaces in steps of `n`.
public enum Indentation: Equatable, Sendable {
    case tabs, spaces(Int)

    /// Read from the file's first lines: tabs if most indented lines start with one; else the widest step (8, 4, 3, 2)
    /// that nine in ten of the indented lines are a multiple of. Nil when nothing is indented.
    public static func detect(_ text: String) -> Indentation? {
        var tabs = 0, widths: [Int] = []
        for line in text.split(whereSeparator: \.isNewline).prefix(2000) {   // "\r\n" is one Character, not "\n"
            if line.hasPrefix("\t") { tabs += 1; continue }
            let n = line.prefix { $0 == " " }.count
            if n > 0, n < line.count { widths.append(n) }
        }
        if tabs > widths.count { return .tabs }
        guard !widths.isEmpty else { return nil }
        let step = [8, 4, 3, 2].first { s in Double(widths.filter { $0 % s == 0 }.count) >= 0.9 * Double(widths.count) } ?? 1
        return .spaces(step)
    }
}
