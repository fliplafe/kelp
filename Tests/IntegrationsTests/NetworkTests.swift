import Foundation
import Testing
import Core
@testable import Integrations

/// Answers requests to the hosts a test registered, and records what was sent. Other hosts go to the network as usual.
class StubURL: URLProtocol, @unchecked Sendable {
    struct Sent { var method: String, path: String, auth: String?, body: String }
    nonisolated(unsafe) private static var routes: [String: (Sent) -> (Int, String)] = [:]
    nonisolated(unsafe) private static var log: [String: [Sent]] = [:]
    private static let lock = NSLock()
    private static let registered: Bool = { URLProtocol.registerClass(StubURL.self); return true }()

    static func serve(_ host: String, _ route: @escaping (Sent) -> (Int, String)) {
        _ = registered
        lock.withLock { routes[host] = route; log[host] = [] }
    }
    static func sent(_ host: String) -> [Sent] { lock.withLock { log[host] ?? [] } }

    override class func canInit(with r: URLRequest) -> Bool { lock.withLock { routes[r.url?.host ?? ""] != nil } }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func stopLoading() {}
    override func startLoading() {
        let r = request, host = r.url?.host ?? ""
        var body = ""
        if let s = r.httpBodyStream {
            s.open(); defer { s.close() }
            var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            body = String(decoding: data, as: UTF8.self)
        } else if let d = r.httpBody { body = String(decoding: d, as: UTF8.self) }
        let sent = Sent(method: r.httpMethod ?? "GET", path: (r.url?.path ?? "") + (r.url?.query.map { "?" + $0 } ?? ""),
            auth: r.value(forHTTPHeaderField: "Authorization"), body: body)
        let route = Self.lock.withLock { Self.log[host, default: []].append(sent); return Self.routes[host] }
        let (code, text) = route?(sent) ?? (500, "")
        let response: URLResponse = HTTPURLResponse(url: r.url ?? URL(fileURLWithPath: "/"), statusCode: code, httpVersion: nil, headerFields: nil) ?? URLResponse()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func basic(_ user: String, _ pass: String) -> String { "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString() }

@Test func jiraSendsBasicAuthAndReadsMyself() async throws {
    let host = "jira-\(UUID().uuidString.prefix(6).lowercased()).test"
    StubURL.serve(host) { _ in (200, #"{"displayName":"Ada"}"#) }
    #expect(try await JiraClient(site: host, email: "a@b.c", token: "tok").myself() == "Ada")
    let s = try #require(StubURL.sent(host).first)
    #expect(s.method == "GET" && s.path == "/rest/api/3/myself" && s.auth == basic("a@b.c", "tok"))
}

@Test func jiraErrorsCarryTheStatusAndAnExcerpt() async throws {
    let host = "jira-\(UUID().uuidString.prefix(6).lowercased()).test"
    StubURL.serve(host) { _ in (401, "bad credentials") }
    await #expect(throws: JiraError.self) { _ = try await JiraClient(site: host, email: "a", token: "b").myself() }
    do { _ = try await JiraClient(site: host, email: "a", token: "b").search() } catch let e as JiraError { #expect(e.description == "Jira 401: bad credentials") }
}

@Test func jiraSearchEncodesTheQuery() async throws {
    let host = "jira-\(UUID().uuidString.prefix(6).lowercased()).test"
    StubURL.serve(host) { _ in
        (200, #"{"issues":[{"key":"ENG-1","fields":{"summary":"Fix","status":{"name":"To Do","statusCategory":{"key":"new"}},"#
            + #""issuetype":{"name":"Bug"},"project":{"key":"ENG"}}}]}"#)
    }
    let issues = try await JiraClient(site: "https://\(host)/", email: "a", token: "b").search(jql: "project = ENG AND text ~ \"a&b\"", max: 5)
    #expect(issues.map(\.key) == ["ENG-1"] && issues[0].url == "https://\(host)/browse/ENG-1")
    let path = try #require(StubURL.sent(host).first?.path)
    #expect(path.contains("maxResults=5") && !path.contains("a&b"))   // the & inside the query is escaped, not a new parameter
}

@Test func jiraMovePrefersTheNamedTransitionThenTheCategory() async throws {
    let host = "jira-\(UUID().uuidString.prefix(6).lowercased()).test"
    let list = #"{"transitions":[{"id":"11","name":"Start","to":{"statusCategory":{"key":"indeterminate"}}},{"id":"21","name":"Ship it","to":{"statusCategory":{"key":"done"}}}]}"#
    StubURL.serve(host) { $0.method == "GET" ? (200, list) : (204, "") }
    let j = JiraClient(site: host, email: "a", token: "b")
    try await j.move(key: "ENG-1", toName: "ship", category: "indeterminate")
    #expect(StubURL.sent(host).last?.body.contains(#""id":"21""#) == true)   // the name wins over the category
    try await j.move(key: "ENG-1", toName: "review", category: "indeterminate")
    #expect(StubURL.sent(host).last?.body.contains(#""id":"11""#) == true)   // no name matches: the category does
    let posts = StubURL.sent(host).filter { $0.method == "POST" }.count
    try await j.move(key: "ENG-1", toName: "review", category: "nothing")
    #expect(StubURL.sent(host).filter { $0.method == "POST" }.count == posts)   // nothing fits: quietly nothing happens
}

@Suite(.serialized) struct FixedHostClients {
    @Test func linearSendsTheKeyAndReadsIssues() async throws {
        StubURL.serve("api.linear.app") { _ in
            (200, #"{"data":{"viewer":{"assignedIssues":{"nodes":[{"id":"i1","identifier":"ENG-1","title":"Fix","description":"","url":"u","#
                + #""branchName":"eng-1","state":{"id":"s","name":"Todo","type":"unstarted"},"team":{"id":"t","key":"ENG","name":"Eng"}}]}}}}"#)
        }
        let issues = try await LinearClient(apiKey: "lin_key").myIssues()
        #expect(issues.map(\.identifier) == ["ENG-1"])
        let s = try #require(StubURL.sent("api.linear.app").first)
        #expect(s.method == "POST" && s.auth == "lin_key" && s.body.contains("assignedIssues"))   // the key goes as is, no Bearer prefix
    }

    @Test func linearReportsGraphQLErrorsAndHTTPFailures() async throws {
        StubURL.serve("api.linear.app") { _ in (400, #"{"errors":[{"message":"nope"}]}"#) }
        await #expect(throws: LinearError.self) { _ = try await LinearClient(apiKey: "k").teams() }
        StubURL.serve("api.linear.app") { _ in (502, "bad gateway") }
        do { _ = try await LinearClient(apiKey: "k").teams(); Issue.record("should have thrown") } catch let e as LinearError { #expect(e.description == "Linear HTTP 502") }
    }

    @Test func linearSetStateFailsWhenTheMutationSaysNo() async throws {
        StubURL.serve("api.linear.app") { _ in (200, #"{"data":{"issueUpdate":{"success":false}}}"#) }
        await #expect(throws: LinearError.self) { try await LinearClient(apiKey: "k").setState(issueId: "i", stateId: "s") }
        StubURL.serve("api.linear.app") { _ in (200, #"{"data":{"issueUpdate":{"success":true}}}"#) }
        try await LinearClient(apiKey: "k").setState(issueId: "i", stateId: "s")
        #expect(StubURL.sent("api.linear.app").last?.body.contains(#""s":"s""#) == true)
    }

    @Test func bitbucketCreatesAPullRequestAndReturnsItsLink() async throws {
        StubURL.serve("api.bitbucket.org") { _ in (201, #"{"links":{"html":{"href":"https://bitbucket.org/w/r/pull-requests/7"}}}"#) }
        let url = try await BitbucketClient(user: "me", token: "t").createPR(workspace: "w", repo: "r", title: "T", body: "B", source: "feat", destination: "main")
        #expect(url == "https://bitbucket.org/w/r/pull-requests/7")
        let s = try #require(StubURL.sent("api.bitbucket.org").first)
        #expect(s.path == "/2.0/repositories/w/r/pullrequests" && s.auth == basic("me", "t"))
        #expect(s.body.contains(#""name":"feat""#) && s.body.contains(#""name":"main""#))
    }

    @Test func bitbucketFailuresNameTheStatus() async throws {
        StubURL.serve("api.bitbucket.org") { _ in (403, "forbidden") }
        do { try await BitbucketClient(user: "u", token: "t").merge(workspace: "w", repo: "r", id: 3); Issue.record("should have thrown") }
        catch let e as BitbucketError { #expect(e.description == "Bitbucket 403: forbidden") }
        StubURL.serve("api.bitbucket.org") { _ in (200, #"{"unexpected":true}"#) }
        await #expect(throws: BitbucketError.self) {
            _ = try await BitbucketClient(user: "u", token: "t").createPR(workspace: "w", repo: "r", title: "", body: "", source: "a", destination: "b")
        }
    }
}

@Test func jiraCredentialsNeverGoOverPlainHttp() async throws {
    let host = "jira-\(UUID().uuidString.prefix(6).lowercased()).test"
    StubURL.serve(host) { _ in (200, #"{"displayName":"Ada"}"#) }
    await #expect(throws: JiraError.self) { _ = try await JiraClient(site: "http://\(host)", email: "a@b.c", token: "secret").myself() }
    #expect(StubURL.sent(host).isEmpty)   // nothing was sent at all
    #expect(try await JiraClient(site: host, email: "a@b.c", token: "secret").myself() == "Ada")   // a bare host means https
}
