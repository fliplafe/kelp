import Foundation
import Core

public struct LinearError: Error, CustomStringConvertible, Sendable { public var description: String }

public struct LinearUser: Codable, Sendable, Equatable {
    public var id: String, name: String
    public var email: String?
}
public struct LinearTeam: Codable, Sendable, Equatable { public var id: String, key: String, name: String }
/// `type` is Linear's state category: triage, backlog, unstarted, started, completed, canceled.
public struct LinearState: Codable, Sendable, Equatable { public var id: String, name: String, type: String }
public struct LinearIssue: Codable, Sendable, Equatable {
    public var id: String, identifier: String, title: String
    public var description: String?
    public var url: String
    public var state: LinearState, team: LinearTeam, branchName: String
}

public struct LinearClient: Sendable {
    public enum StateKind: Sendable { case inProgress, inReview, done }

    public var apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }

    static let issueFields = "id identifier title description url branchName state { id name type } team { id key name }"
    static let openFilter = #"filter: { state: { type: { nin: ["completed", "canceled"] } } }, orderBy: updatedAt"#

    public func viewer() async throws -> LinearUser {
        try Self.parse(LinearUser.self, from: await request("{ viewer { id name email } }"), at: "viewer")
    }

    /// Open issues assigned to the API key's user.
    public func myIssues() async throws -> [LinearIssue] {
        let q = "{ viewer { assignedIssues(first: 100, \(Self.openFilter)) { nodes { \(Self.issueFields) } } } }"
        return try Self.parse([LinearIssue].self, from: await request(q), at: "viewer", "assignedIssues", "nodes")
    }

    public func teamIssues(teamId: String) async throws -> [LinearIssue] {
        let q = "query($id: String!) { team(id: $id) { issues(first: 100, \(Self.openFilter)) { nodes { \(Self.issueFields) } } } }"
        return try Self.parse([LinearIssue].self, from: await request(q, ["id": .string(teamId)]), at: "team", "issues", "nodes")
    }

    public func teams() async throws -> [LinearTeam] {
        try Self.parse([LinearTeam].self, from: await request("{ teams { nodes { id key name } } }"), at: "teams", "nodes")
    }

    public func workflowStates(teamId: String) async throws -> [LinearState] {
        let q = "query($id: String!) { team(id: $id) { states { nodes { id name type } } } }"
        return try Self.parse([LinearState].self, from: await request(q, ["id": .string(teamId)]), at: "team", "states", "nodes")
    }

    public func setState(issueId: String, stateId: String) async throws {
        let q = "mutation($id: String!, $s: String!) { issueUpdate(id: $id, input: { stateId: $s }) { success } }"
        let ok = try Self.parse(Bool.self, from: await request(q, ["id": .string(issueId), "s": .string(stateId)]), at: "issueUpdate", "success")
        if !ok { throw LinearError(description: "Linear issueUpdate returned success=false") }
    }

    func request(_ query: String, _ variables: [String: JSONValue] = [:]) async throws -> Data {
        guard let url = URL(string: "https://api.linear.app/graphql") else { throw LinearError(description: "bad Linear URL") }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue(apiKey, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(JSONValue.object(["query": .string(query), "variables": .object(variables)]))
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // GraphQL errors come back as 400 with an `errors` body; let parse() report those.
        if code != 200, (try? JSONDecoder().decode(JSONValue.self, from: data))?["errors"] == nil {
            throw LinearError(description: "Linear HTTP \(code)")
        }
        return data
    }

    /// Decode `data.<path...>` from a GraphQL response, throwing on `errors`.
    public static func parse<T: Decodable>(_: T.Type, from data: Data, at path: String...) throws -> T {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        if let errs = root["errors"]?.array, !errs.isEmpty {
            throw LinearError(description: "Linear: " + errs.map { $0["message"]?.string ?? "error" }.joined(separator: "; "))
        }
        guard let v = path.reduce(root["data"], { $0?[$1] }), v != .null else {
            throw LinearError(description: "Linear: missing data." + path.joined(separator: "."))
        }
        return try v.decode(T.self)
    }

    /// Pick the team state to move an issue to. inReview is nil when the team has no review-like state.
    public static func stateFor(kind: StateKind, in states: [LinearState]) -> LinearState? {
        let isReview = { (s: LinearState) in s.name.lowercased().contains("review") }
        switch kind {
        case .inReview:
            return states.first(where: isReview)
        case .inProgress:
            let started = states.filter { $0.type == "started" && !isReview($0) }
            return started.first { $0.name.lowercased() == "in progress" } ?? started.first
        case .done:
            let done = states.filter { $0.type == "completed" }
            return done.first { $0.name.lowercased() == "done" } ?? done.first
        }
    }
}
