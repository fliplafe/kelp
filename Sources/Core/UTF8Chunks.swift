import Foundation

/// Output read in chunks can end inside a character (a read of 64 KB cuts "…" in two): decoded alone, each half would
/// read as U+FFFD. The cut-off bytes are kept for the next chunk instead.
public enum UTF8Chunks {
    /// `d` split into what decodes whole and the start of a character it ends in (at most 3 bytes).
    public static func split(_ d: Data) -> (whole: Data, rest: Data) {
        let end = d.endIndex
        var i = end
        while i > d.startIndex, end - i < 3, d[d.index(before: i)] & 0xC0 == 0x80 { i = d.index(before: i) }
        guard i > d.startIndex else { return (d, Data()) }
        let lead = d[d.index(before: i)], start = d.index(before: i)
        let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return end - start < length ? (d[..<start], d[start...]) : (d, Data())
    }
}
