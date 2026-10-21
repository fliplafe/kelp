import Foundation
import Core

public enum ReviewMessage {
    /// All open comments as one message for the agent: file, lines, code quote, remark.
    public static func compose(branch: String, comments: [DiffComment]) -> String {
        var s = "Review comments on branch \(branch). Please address each one:\n"
        for (i, c) in comments.enumerated() {
            let range = c.startLine == c.endLine ? "\(c.startLine)" : "\(c.startLine)-\(c.endLine)"
            s += "\n\(i + 1). \(c.file):\(range)\n"
            for l in c.quote.split(separator: "\n", omittingEmptySubsequences: false) { s += "   > \(l)\n" }
            s += "   \(c.text)\n"
        }
        return s
    }
}
