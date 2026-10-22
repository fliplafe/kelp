import Foundation

/// A commit subject read as a Conventional Commit ("fix(daemon): stop …"): the type and scope apart from the words, so
/// the graph shows a mark and the change instead of the prefix. A subject without one, or with a type not in `types`,
/// stays as written.
public struct CommitSubject: Equatable, Sendable {
    public static let types: Set<String> = ["feat", "fix", "refactor", "perf", "docs", "test", "build", "ci", "chore", "style", "revert"]
    public var type: String?
    public var scope: String?
    public var breaking = false
    public var text: String

    public init(_ subject: String) {
        text = subject
        guard let m = subject.wholeMatch(of: /(\w+)(?:\(([^()]+)\))?(!)?:\s+(.+)/), Self.types.contains(m.1.lowercased()) else { return }
        type = m.1.lowercased(); scope = m.2.map(String.init); breaking = m.3 != nil
        text = Self.capitalized(String(m.4))
    }

    /// "open the file" → "Open the file", as a sentence reads once the prefix is gone. A first word that isn't plain
    /// lowercase ("SIGKILL", "kelp.json", "iOS") is a name and stays as it is.
    static func capitalized(_ s: String) -> String {
        let word = s.prefix { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
        guard let first = word.first, word.allSatisfy({ ($0.isLetter && $0.isLowercase) || $0 == "'" || $0 == "’" }) else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
