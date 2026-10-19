import Foundation

/// Links to a file on the repository's website (GitHub, GitLab, Bitbucket) at the commit checked out now.
extension Git {
    /// `path` absolute; `lines` 1-based. Fails when origin isn't on a website Krill knows how to link to.
    public static func webURL(path: String, lines: ClosedRange<Int>?) throws -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let top = try run(["rev-parse", "--show-toplevel"], cwd: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = try run(["remote", "get-url", "origin"], cwd: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        let sha = try run(["rev-parse", "HEAD"], cwd: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path, root = URL(fileURLWithPath: top).resolvingSymlinksInPath().path
        let file = real.hasPrefix(root + "/") ? String(real.dropFirst(root.count + 1)) : (path as NSString).lastPathComponent
        guard let url = webURL(remote: remote, sha: sha, file: file, lines: lines) else {
            throw GitError(args: ["remote", "get-url", "origin"], status: 1, stderr: "origin (\(remote)) isn't a GitHub, GitLab or Bitbucket address")
        }
        return url
    }

    static func webURL(remote: String, sha: String, file: String, lines: ClosedRange<Int>?) -> String? {
        guard let (host, repo) = webRepo(remote) else { return nil }
        let f = file.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let base = "https://\(host)/\(repo)"
        if host.contains("gitlab") {
            return "\(base)/-/blob/\(sha)/\(f)" + (lines.map { $0.count == 1 ? "#L\($0.lowerBound)" : "#L\($0.lowerBound)-\($0.upperBound)" } ?? "")
        }
        if host.contains("bitbucket") {
            return "\(base)/src/\(sha)/\(f)" + (lines.map { $0.count == 1 ? "#lines-\($0.lowerBound)" : "#lines-\($0.lowerBound):\($0.upperBound)" } ?? "")
        }
        return "\(base)/blob/\(sha)/\(f)" + (lines.map { $0.count == 1 ? "#L\($0.lowerBound)" : "#L\($0.lowerBound)-L\($0.upperBound)" } ?? "")
    }

    /// `git@github.com:o/r.git`, `ssh://git@host:22/o/r`, `https://user@host/o/r.git` → (host, "o/r").
    static func webRepo(_ remote: String) -> (String, String)? {
        var s = remote
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let at = s.firstIndex(of: "@"), s[..<at].contains("/") == false { s = String(s[s.index(after: at)...]) }
        guard let sep = s.firstIndex(where: { $0 == "/" || $0 == ":" }) else { return nil }
        let host = String(s[..<sep])
        var path = String(s[s.index(after: sep)...])
        if let first = path.split(separator: "/").first, Int(first) != nil { path = path.split(separator: "/").dropFirst().joined(separator: "/") }   // ssh port
        if path.hasSuffix(".git") { path.removeLast(4) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, path.contains("/") else { return nil }
        return (host, path)
    }
}
