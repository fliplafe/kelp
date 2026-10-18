import Foundation
import GitKit

public struct BitbucketError: Error, CustomStringConvertible, Sendable { public var description: String }

/// Bitbucket Cloud pull requests (REST 2.0, Basic auth user:token). Shapes map onto `GitHub.PullRequest` so the UI is shared.
public struct BitbucketClient: Sendable {
    public var user: String, token: String
    public init(user: String, token: String) { self.user = user; self.token = token }

    /// "git@bitbucket.org:team/repo.git" / "https://bitbucket.org/team/repo" → ("team", "repo")
    public static func slug(remote: String) -> (workspace: String, repo: String)? {
        guard let r = remote.range(of: "bitbucket.org") else { return nil }
        var rest = remote[r.upperBound...].drop { $0 == "/" || $0 == ":" }
        if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
        let parts = rest.split(separator: "/")
        return parts.count >= 2 ? (String(parts[0]), String(parts[1])) : nil
    }

    public static func slug(cwd: String) -> (workspace: String, repo: String)? {
        (try? Git.run(["remote", "get-url", "origin"], cwd: cwd)).flatMap { slug(remote: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public func pullRequests(workspace: String, repo: String) async throws -> [GitHub.PullRequest] {
        try Self.parsePullRequests(await request("GET", "/repositories/\(workspace)/\(repo)/pullrequests?state=OPEN&pagelen=50"))
    }

    public func createPR(workspace: String, repo: String, title: String, body: String, source: String, destination: String) async throws -> String {
        let d = try await request("POST", "/repositories/\(workspace)/\(repo)/pullrequests", body: [
            "title": title, "description": body,
            "source": ["branch": ["name": source]], "destination": ["branch": ["name": destination]],
        ])
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let html = ((o["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String else { throw BitbucketError(description: "unexpected create response") }
        return html
    }

    public func merge(workspace: String, repo: String, id: Int) async throws {
        _ = try await request("POST", "/repositories/\(workspace)/\(repo)/pullrequests/\(id)/merge", body: ["merge_strategy": "squash"])
    }

    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: "https://api.bitbucket.org/2.0" + path) else { throw BitbucketError(description: "bad URL") }
        var r = URLRequest(url: url); r.httpMethod = method
        r.setValue("Basic " + Data("\(user):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw BitbucketError(description: "Bitbucket \(code): \(String(decoding: d.prefix(300), as: UTF8.self))") }
        return d
    }

    public static func parsePullRequests(_ d: Data) throws -> [GitHub.PullRequest] {
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any], let vals = o["values"] as? [[String: Any]] else {
            throw BitbucketError(description: "unexpected pullrequests response")
        }
        return vals.compactMap { v in
            guard let id = v["id"] as? Int else { return nil }
            let html = ((v["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String ?? ""
            let branch = ((v["source"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String ?? ""
            return GitHub.PullRequest(number: id, title: v["title"] as? String ?? "", url: html,
                                      author: (v["author"] as? [String: Any])?["display_name"] as? String ?? "", headRefName: branch,
                                      isDraft: v["draft"] as? Bool ?? false, state: v["state"] as? String ?? "OPEN", reviewDecision: nil, checks: .init())
        }
    }
}
