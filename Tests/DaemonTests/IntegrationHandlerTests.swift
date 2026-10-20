import Foundation
import Testing
import Core
import GitKit
import Agents
@testable import Daemon

/// Answers the hosts a test registered (nothing else is touched); a second copy of the stub in IntegrationsTests, since
/// test targets can't share code.
private class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (String, String) -> (Int, String)] = [:]   // host -> (path, body) -> (status, reply)
    private static let lock = NSLock()
    private static let registered: Bool = { URLProtocol.registerClass(Stub.self); return true }()
    static func serve(_ host: String, _ f: @escaping (String, String) -> (Int, String)) { _ = registered; lock.withLock { routes[host] = f } }
    override class func canInit(with r: URLRequest) -> Bool { lock.withLock { routes[r.url?.host ?? ""] != nil } }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func stopLoading() {}
    override func startLoading() {
        let r = request
        var body = ""
        if let s = r.httpBodyStream {
            s.open(); defer { s.close() }
            var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            body = String(decoding: data, as: UTF8.self)
        } else if let d = r.httpBody { body = String(decoding: d, as: UTF8.self) }
        let route = Self.lock.withLock { Self.routes[r.url?.host ?? ""] }
        let (code, text) = route?(r.url?.path ?? "", body) ?? (500, "")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: r.url ?? URL(fileURLWithPath: "/"), statusCode: code, httpVersion: nil, headerFields: nil) ?? URLResponse(), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func isolated() { _ = isolatedKeychain }
private func clearKeys() { for a in [Daemon.linearKeyAccount, Daemon.jiraAccount, Daemon.bitbucketAccount] { Keychain.delete(a) } }

private func daemon() async throws -> (d: Daemon, c: RPCClient) {
    isolated()
    let root = tmp(); let d = try Daemon(root: root); try d.start()
    return (d, try RPCClient(socket: root.appendingPathComponent("kelp.sock").path))
}

private let viewer = #"{"data":{"viewer":{"id":"u1","name":"Ada","email":"ada@x.io"}}}"#

// These share one set of keychain accounts (and Linear / Bitbucket have fixed hosts), so they run one after another.
@Suite(.serialized) struct FixedHostHandlers {
    @Test func linearIsValidatedBeforeItsKeyIsKept() async throws {
        let (d, c) = try await daemon(); defer { d.stop(); clearKeys() }
        #expect(try await c.call("linear.status")["connected"]?.bool == false)
        Stub.serve("api.linear.app") { _, _ in (401, "nope") }
        await #expect(throws: (any Error).self) { _ = try await c.call("linear.setKey", .obj(["key": "bad"])) }
        #expect(try await c.call("linear.status")["connected"]?.bool == false)   // the bad key wasn't saved
        Stub.serve("api.linear.app") { _, _ in (200, viewer) }
        #expect(try await c.call("linear.setKey", .obj(["key": "good"]))["name"]?.string == "Ada")
        let s = try await c.call("linear.status")
        #expect(s["connected"]?.bool == true && s["name"]?.string == "Ada")
        _ = try await c.call("linear.setKey", .obj(["key": ""]))   // an empty key disconnects
        #expect(try await c.call("linear.status")["connected"]?.bool == false)
    }

    @Test func linearListsIssuesTeamsStatesAndMovesAnIssue() async throws {
        let (d, c) = try await daemon(); defer { d.stop(); clearKeys() }
        Stub.serve("api.linear.app") { _, body in
            if body.contains("viewer { id name email }") { return (200, viewer) }
            if body.contains("assignedIssues") { return (200, #"{"data":{"viewer":{"assignedIssues":{"nodes":[{"id":"i1","identifier":"ENG-1","title":"Fix","description":"","url":"u","branchName":"eng-1","state":{"id":"s","name":"Todo","type":"unstarted"},"team":{"id":"t","key":"ENG","name":"Eng"}}]}}}}"#) }
            if body.contains("teams {") { return (200, #"{"data":{"teams":{"nodes":[{"id":"t","key":"ENG","name":"Eng"}]}}}"#) }
            if body.contains("states {") { return (200, #"{"data":{"team":{"states":{"nodes":[{"id":"s1","name":"Todo","type":"unstarted"},{"id":"s2","name":"In Progress","type":"started"}]}}}}"#) }
            if body.contains("issueUpdate") { return (200, #"{"data":{"issueUpdate":{"success":true}}}"#) }
            return (400, #"{"errors":[{"message":"unexpected"}]}"#)
        }
        _ = try await c.call("linear.setKey", .obj(["key": "k"]))
        #expect(try await c.call("linear.issues").array?.first?["identifier"]?.string == "ENG-1")
        #expect(try await c.call("linear.teams").array?.first?["key"]?.string == "ENG")
        #expect(try await c.call("linear.states", .obj(["teamId": "t"])).array?.count == 2)
        _ = try await c.call("linear.setState", .obj(["issueId": "i1", "stateId": "s2"]))
        await #expect(throws: (any Error).self) { _ = try await c.call("linear.states", .obj([:])) }   // the team id is required
    }

    @Test func withoutALinearKeyListsAreEmptyAndIssuesAskForTheKey() async throws {
        let (d, c) = try await daemon(); defer { d.stop(); clearKeys() }
        clearKeys()
        #expect(try await c.call("linear.teams").array?.isEmpty == true)
        await #expect(throws: (any Error).self) { _ = try await c.call("linear.issues") }
        await #expect(throws: (any Error).self) { _ = try await c.call("linear.setState", .obj(["issueId": "i", "stateId": "s"])) }
    }

    @Test func bitbucketCredentialsAreKeptOrCleared() async throws {
        let (d, c) = try await daemon(); defer { d.stop(); clearKeys() }
        clearKeys()
        #expect(try await c.call("bitbucket.status")["connected"]?.bool == false)
        _ = try await c.call("bitbucket.setCredentials", .obj(["user": "me", "token": "t"]))
        #expect(try await c.call("bitbucket.status")["connected"]?.bool == true)
        _ = try await c.call("bitbucket.setCredentials", .obj(["user": "me", "token": ""]))
        #expect(try await c.call("bitbucket.status")["connected"]?.bool == false)
    }

    @Test func jiraIsValidatedListsIssuesAndMovesThem() async throws {
        let host = "jira-\(UUID().uuidString.prefix(6).lowercased()).test"
        let (d, c) = try await daemon(); defer { d.stop(); clearKeys() }
        clearKeys()
        #expect(try await c.call("jira.status")["connected"]?.bool == false)
        await #expect(throws: (any Error).self) { _ = try await c.call("jira.issues") }
        #expect(try await c.call("jira.transitions", .obj(["key": "ENG-1"])).array?.isEmpty == true)   // not connected: nothing to list
        let moves = Moves()
        Stub.serve(host) { path, body in
            if path.hasSuffix("/myself") { return (200, #"{"displayName":"Ada"}"#) }
            if path.contains("/search") { return (200, #"{"issues":[{"key":"ENG-1","fields":{"summary":"Fix","status":{"name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"name":"Bug"},"project":{"key":"ENG"}}}]}"#) }
            if path.hasSuffix("/transitions"), body.isEmpty { return (200, #"{"transitions":[{"id":"11","name":"Start","to":{"statusCategory":{"key":"indeterminate"}}}]}"#) }
            if path.hasSuffix("/transitions") { moves.add(body); return (204, "") }
            return (404, "")
        }
        #expect(try await c.call("jira.setCredentials", .obj(["site": .string(host), "email": "a@b.c", "token": "tok"]))["name"]?.string == "Ada")
        let st = try await c.call("jira.status")
        #expect(st["connected"]?.bool == true && st["name"]?.string == "Ada")
        #expect(try await c.call("jira.issues").array?.first?["key"]?.string == "ENG-1")
        #expect(try await c.call("jira.transitions", .obj(["key": "ENG-1"])).array?.first?["id"]?.string == "11")
        _ = try await c.call("jira.transition", .obj(["key": "ENG-1", "id": "11"]))
        #expect(moves.all.contains { $0.contains(#""id":"11""#) })
        _ = try await c.call("jira.setCredentials", .obj(["site": .string(host), "email": "a@b.c", "token": ""]))
        #expect(try await c.call("jira.status")["connected"]?.bool == false)
    }
}

private final class Moves: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

@Test func agentSecretsGoToTheKeychainAndAnEmptyValueRemovesThem() async throws {
    let (d, c) = try await daemon(); defer { d.stop() }
    let agent = "demo-\(UUID().uuidString.prefix(6))"
    let account = AgentManifest.secretAccount(agent: agent, key: "API_KEY")
    defer { Keychain.delete(account) }
    #expect(Keychain.get(account) == nil)
    _ = try await c.call("agent.setSecret", .obj(["agent": .string(agent), "key": "API_KEY", "value": "s3cret"]))
    #expect(Keychain.get(account) == "s3cret")
    _ = try await c.call("agent.setSecret", .obj(["agent": .string(agent), "key": "API_KEY", "value": ""]))
    #expect(Keychain.get(account) == nil)
}
