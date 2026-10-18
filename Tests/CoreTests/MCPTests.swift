import Foundation
import Testing
@testable import Core

/// Records daemon calls; answers a few the way the daemon would.
final class FakeDaemon: @unchecked Sendable {
    private let l = NSLock(); private var log: [(String, JSONValue)] = []
    var calls: [(String, JSONValue)] { l.withLock { log } }
    func call(_ m: String, _ p: JSONValue) throws -> JSONValue {
        l.withLock { log.append((m, p)) }
        switch m {
        case "worktree.list": return .array([.obj(["id": "w1", "path": "/tmp/proj"])])
        case "ui.state": return .object([:])
        case "settings.get": return .obj(["a.b": 1, "extensions.disabled": .array(["old"])])
        case "session.send": throw RPCError.invalidParams("no live session x")
        default: return .obj(["delivered": 1])
        }
    }
}

func mcp(_ fake: FakeDaemon, dir: URL = FileManager.default.temporaryDirectory) -> MCPServer {
    MCPServer(version: "1.2", cwd: "/tmp/proj", extensionsDir: dir, call: { try fake.call($0, $1) },
              scaffold: { try IDE.scaffoldExtension(id: $0, name: $1, description: $2, in: dir) })
}

func reply(_ s: MCPServer, _ request: String) async throws -> JSONValue {
    let line = try #require(await s.handle(request))
    return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
}

func callTool(_ s: MCPServer, _ name: String, _ args: String = "{}") async throws -> JSONValue {
    let r = try await reply(s, #"{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#)
    return try #require(r["result"])
}

@Test func mcpInitializeAndList() async throws {
    let s = mcp(FakeDaemon())
    let r = try await reply(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}"#)
    #expect(r["id"] == 1)
    #expect(r["result"]?["protocolVersion"] == "2025-03-26")
    #expect(r["result"]?["serverInfo"]?["name"] == "krill")
    #expect(r["result"]?["capabilities"]?["tools"] == .object([:]))
    #expect(await s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    #expect(try await reply(s, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)["result"] == .object([:]))

    let tools = try await reply(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)["result"]?["tools"]?.array ?? []
    let names = Set(tools.compactMap { $0["name"]?.string })
    #expect(names == ["krill_open", "krill_ui_state", "krill_settings_get", "krill_settings_set", "krill_extensions_list", "krill_extension_create",
                      "krill_extension_set_enabled", "krill_extensions_reload", "krill_run_command", "krill_sessions_list", "krill_session_send"])
    #expect(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" && $0["description"]?.string?.isEmpty == false })
    #expect(try await reply(s, #"{"jsonrpc":"2.0","id":4,"method":"nope"}"#)["error"]?["code"] == -32601)
}

@Test func mcpToolsRouteToDaemon() async throws {
    let fake = FakeDaemon(), s = mcp(fake)
    _ = try await callTool(s, "krill_open", #"{"uri":"src/a.swift:12","split":"right"}"#)
    let open = try #require(fake.calls.last { $0.0 == "ui.open" }?.1)
    #expect(open["uri"] == "file:///tmp/proj/src/a.swift#L12")
    #expect(open["split"] == "right" && open["worktreeId"] == "w1")

    #expect(try await callTool(s, "krill_settings_get", #"{"key":"a.b"}"#)["content"]?.array?.first?["text"] == "1")
    _ = try await callTool(s, "krill_settings_set", #"{"key":"x","value":[1]}"#)
    #expect(fake.calls.last?.0 == "settings.set" && fake.calls.last?.1["value"] == .array([1]))

    _ = try await callTool(s, "krill_extension_set_enabled", #"{"id":"docker","enabled":false}"#)
    #expect(fake.calls.last?.1["value"] == .array(["old", "docker"]))
    _ = try await callTool(s, "krill_run_command", #"{"id":"x.y","args":{"n":2}}"#)
    #expect(fake.calls.last?.0 == "ui.command" && fake.calls.last?.1["args"]?["n"] == 2)

    let failed = try await callTool(s, "krill_session_send", #"{"id":"x","text":"hi"}"#)
    #expect(failed["isError"] == true)
    #expect(failed["content"]?.array?.first?["text"] == "no live session x")
    #expect(try await callTool(s, "krill_open")["isError"] == true)   // missing uri
}

@Test func mcpCreatesExtensions() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kx-\(UUID().uuidString.prefix(8))")
    let fake = FakeDaemon(), s = mcp(fake, dir: dir)
    let r = try await callTool(s, "krill_extension_create", #"{"id":"my-thing","description":"Demo"}"#)
    #expect(r["isError"] == nil)
    #expect(r["content"]?.array?.first?["text"]?.string?.contains("EXTENSIONS.md") == true)
    let list = try await callTool(s, "krill_extensions_list")["content"]?.array?.first?["text"]?.string ?? ""
    #expect(list.contains("\"My Thing\""))
    #expect(try await callTool(s, "krill_extension_create", #"{"id":"../evil"}"#)["isError"] == true)
}

@Test func extensionGuideMatchesDocs() throws {
    let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/extensions.md")
    #expect(ExtensionGuide.markdown == (try String(contentsOf: doc, encoding: .utf8)), "regenerate Sources/Core/ExtensionGuide.swift from docs/extensions.md")
}

/// The starter's list command must print one JSON object per line using only stock tools.
@Test func scaffoldedExtensionWorks() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kx-\(UUID().uuidString.prefix(8))")
    let folder = try IDE.scaffoldExtension(id: "files", name: nil, description: "Top-level files", in: dir)
    #expect(try String(contentsOf: dir.appendingPathComponent("EXTENSIONS.md"), encoding: .utf8) == ExtensionGuide.markdown)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
    let m = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent("extension.json")))
    #expect(m["id"] == "files" && m["description"] == "Top-level files")
    let command = try #require(m["contributes"]?["panels"]?.array?.first?["list"]?["command"]?.string)

    let work = dir.appendingPathComponent("work"); try Paths.ensure(work)
    try "hi".write(to: work.appendingPathComponent("a b.txt"), atomically: true, encoding: .utf8)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", command]; p.currentDirectoryURL = work
    let out = Pipe(); p.standardOutput = out
    try p.run(); p.waitUntilExit()
    let rows = (String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").split(separator: "\n")
        .compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    #expect(rows == [.obj(["name": "./a b.txt", "size": 2])])

    #expect(throws: RPCError.self) { try IDE.scaffoldExtension(id: "files", name: nil, description: nil, in: dir) }   // exists
    #expect(!IDE.isValidExtensionID("Bad_ID") && !IDE.isValidExtensionID("..") && IDE.isValidExtensionID("docker.compose-2"))
}

@Test func openTargets() {
    #expect(IDE.uri(for: "https://x.dev/a", cwd: "/w") == "https://x.dev/a")
    #expect(IDE.uri(for: "a/b.swift", cwd: "/w") == "/w/a/b.swift")
    #expect(IDE.uri(for: "/abs/../c.swift", cwd: "/w") == "/c.swift")
    #expect(IDE.uri(for: "my file.swift:7", cwd: "/w") == "file:///w/my%20file.swift#L7")
    #expect(IDE.uri(for: "session:abc-def", cwd: "/w") == "session:abc-def")
}
