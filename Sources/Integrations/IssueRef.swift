import Foundation

/// Maps between issue references (`#123`, `ENG-123`) and branch names (`123-fix-login`, `eng-123-fix-login`).
public enum IssueRef {
    public static func branchName(_ ref: String, title: String) -> String {
        let words = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.prefix(6)
        return ([ref.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#"))] + words.map(String.init)).joined(separator: "-")
    }

    public static func branchName(_ number: Int, title: String) -> String { branchName(String(number), title: title) }

    /// Last path component only, so `user/eng-123-foo` works. Keys need 2+ letters to skip things like `v2-...`.
    public static func parse(fromBranch branch: String) -> String? {
        let name = branch.split(separator: "/").last.map(String.init) ?? branch
        if let m = name.firstMatch(of: #/^([A-Za-z]{2,})-(\d+)(?:-|$)/#) { return "\(m.1.uppercased())-\(m.2)" }
        if let m = name.firstMatch(of: #/^(\d+)(?:-|$)/#) { return "#\(m.1)" }
        return nil
    }
}
