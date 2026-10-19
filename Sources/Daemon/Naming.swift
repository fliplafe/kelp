import Foundation

/// Tab titles and branch names from a task prompt.
enum Naming {
    static let stop: Set<String> = ["a", "an", "the", "to", "and", "of", "for", "in", "on", "with", "please", "can", "you", "it", "this", "that", "is", "be", "we"]
    /// "Add a dark-mode toggle to Settings!" -> "add-dark-mode-toggle-settings"
    static func slug(_ s: String, words: Int = 5) -> String {
        let parts = s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { !stop.contains($0) && $0.allSatisfy(\.isASCII) }
        return parts.prefix(words).joined(separator: "-")
    }
    static func title(_ s: String) -> String {
        let first = s.split(separator: "\n").first.map(String.init) ?? s
        return first.count > 40 ? String(first.prefix(39)) + "…" : first
    }
}
