import Foundation

/// `krill mcp`: the Model Context Protocol over stdio (newline-delimited JSON-RPC 2.0), so agents can drive the IDE with tools.
public final class MCPServer: Sendable {
    /// Creates an extension folder (id, name, description) and returns it.
    public typealias Scaffold = @Sendable (String, String?, String?) throws -> URL

    let version: String
    let cwd: String
    let extensionsDir: URL
    let call: IDE.Call
    let scaffold: Scaffold

    public init(version: String, cwd: String = FileManager.default.currentDirectoryPath, extensionsDir: URL = Paths.extensions,
                call: @escaping IDE.Call, scaffold: @escaping Scaffold) {
        self.version = version; self.cwd = cwd; self.extensionsDir = extensionsDir; self.call = call; self.scaffold = scaffold
    }

    /// One incoming line → the reply line, or nil for notifications.
    public func handle(_ line: String) async -> String? {
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), let method = msg["method"]?.string else {
            return Self.encode(.obj(["jsonrpc": "2.0", "id": .null, "error": .obj(["code": -32700, "message": "parse error"])]))
        }
        guard let id = msg["id"] else { return nil }   // notifications/initialized and friends
        let params = msg["params"] ?? .null
        var reply: [String: JSONValue] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "initialize":
            reply["result"] = .obj(["protocolVersion": params["protocolVersion"] ?? "2025-06-18", "capabilities": .obj(["tools": .object([:])]),
                                    "serverInfo": .obj(["name": "krill", "version": .string(version)])])
        case "ping": reply["result"] = .object([:])
        case "tools/list": reply["result"] = .obj(["tools": .array(Self.tools.map(\.json))])
        case "tools/call":
            let name = params["name"]?.string ?? ""
            guard Self.tools.contains(where: { $0.name == name }) else {
                reply["error"] = .obj(["code": -32602, "message": .string("unknown tool \(name)")]); break
            }
            reply["result"] = await run(name, params["arguments"] ?? .object([:]))
        default: reply["error"] = .obj(["code": -32601, "message": .string("method not found: \(method)")])
        }
        return Self.encode(.object(reply))
    }

    /// Tool results: text content; failures (daemon errors, bad arguments) are `isError` results the agent can read.
    func run(_ tool: String, _ a: JSONValue) async -> JSONValue {
        do { return .obj(["content": .array([.obj(["type": "text", "text": .string(try await text(tool, a))])])]) }
        catch {
            let message = (error as? RPCError)?.message ?? "\(error)"
            return .obj(["content": .array([.obj(["type": "text", "text": .string(message)])]), "isError": true])
        }
    }

    func text(_ tool: String, _ a: JSONValue) async throws -> String {
        func req(_ k: String) throws -> String {
            guard let s = a[k]?.string, !s.isEmpty else { throw RPCError.invalidParams("missing \(k)") }
            return s
        }
        switch tool {
        case "krill_open": return Self.pretty(try await IDE.open(try req("uri"), split: a["split"]?.string, cwd: cwd, call: call))
        case "krill_ui_state": return Self.pretty(try await call("ui.state", .null))
        case "krill_settings_get":
            let all = try await call("settings.get", .null)
            return Self.pretty(a["key"]?.string.map { all[$0] ?? .null } ?? all)
        case "krill_settings_set":
            _ = try await call("settings.set", .obj(["key": .string(try req("key")), "value": a["value"] ?? .null]))
            return "ok"
        case "krill_extensions_list": return Self.pretty(try await IDE.extensions(call: call, dir: extensionsDir))
        case "krill_extension_create":
            let folder = try scaffold(try req("id"), a["name"]?.string, a["description"]?.string)
            let guide = folder.deletingLastPathComponent().appendingPathComponent("EXTENSIONS.md").path
            return "Created \(folder.path) (extension.json + README.md, a working list-panel example). Read the authoring guide \(guide) first, "
                + "then edit \(folder.path)/extension.json. Krill reloads extensions when their files change; krill_extensions_reload forces it."
        case "krill_extension_set_enabled":
            guard let on = a["enabled"]?.bool else { throw RPCError.invalidParams("missing enabled") }
            try await IDE.setExtension(try req("id"), enabled: on, call: call)
            return "ok"
        case "krill_extensions_reload": return Self.pretty(try await call("ui.command", .obj(["id": "extensions.reload"])))
        case "krill_run_command":
            var p: [String: JSONValue] = ["id": .string(try req("id"))]
            if let args = a["args"] { p["args"] = args }
            return Self.pretty(try await call("ui.command", .object(p)))
        case "krill_sessions_list": return Self.pretty(try await call("session.list", .null))
        case "krill_session_send":
            _ = try await call("session.send", .obj(["id": .string(try req("id")), "text": .string(try req("text"))]))
            return "ok"
        default: throw RPCError.invalidParams("unknown tool \(tool)")
        }
    }

    static func encode(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = .withoutEscapingSlashes
        return (try? e.encode(v)).flatMap { String(bytes: $0, encoding: .utf8) } ?? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encoding failed"}}"#
    }

    static func pretty(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "null"
    }

    struct Tool {
        let name: String, description: String, properties: [String: JSONValue], required: [String]
        var json: JSONValue {
            .obj(["name": .string(name), "description": .string(description),
                  "inputSchema": .obj(["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })])])
        }
    }

    static func prop(_ type: String?, _ description: String) -> JSONValue {
        var o: [String: JSONValue] = ["description": .string(description)]
        if let type { o["type"] = .string(type) }
        return .object(o)
    }

    static let tools: [Tool] = [
        Tool(name: "krill_open", description: "Open a file (path or path:line), URL or Krill tab URI (session:<id>, diff:<path>, ext:<extension>/<view>) as a tab in the Krill editor area.",
             properties: ["uri": prop("string", "Path (relative to your working directory is fine), path:line, http(s) URL or tab URI"),
                          "split": .obj(["type": "string", "enum": .array(["right", "down"]), "description": "Open in a new split instead of the current group"])],
             required: ["uri"]),
        Tool(name: "krill_ui_state", description: "What the Krill app is showing right now: workspace, open tabs, extensions, commands.", properties: [:], required: []),
        Tool(name: "krill_settings_get", description: "Read Krill settings (~/.krill/settings.json, flat dotted keys); one key or all of them.",
             properties: ["key": prop("string", "Setting key, e.g. sessions.hibernateMinutes; omit for all")], required: []),
        Tool(name: "krill_settings_set", description: "Change a Krill setting; the app applies it immediately. A null value removes the key.",
             properties: ["key": prop("string", "Setting key"), "value": prop(nil, "Any JSON value; null removes the key")], required: ["key", "value"]),
        Tool(name: "krill_extensions_list", description: "List Krill extensions (built-in and ~/.krill/extensions) with whether each is enabled.", properties: [:], required: []),
        Tool(name: "krill_extension_create", description: "Create a new Krill extension folder with a working starter extension.json; read the EXTENSIONS.md guide it points to before editing.",
             properties: ["id": prop("string", "Lowercase letters, digits, dots and dashes, e.g. docker"), "name": prop("string", "Display name"),
                          "description": prop("string", "One line about what it does")], required: ["id"]),
        Tool(name: "krill_extension_set_enabled", description: "Enable or disable a Krill extension by id.",
             properties: ["id": prop("string", "Extension id"), "enabled": prop("boolean", "true to enable, false to disable")], required: ["id", "enabled"]),
        Tool(name: "krill_extensions_reload", description: "Reload all Krill extensions after editing their files; load errors show in Settings → Extensions.", properties: [:], required: []),
        Tool(name: "krill_run_command", description: "Run a Krill command-palette command by id (krill_ui_state lists them).",
             properties: ["id": prop("string", "Command id, e.g. extensions.reload"), "args": prop(nil, "Optional arguments for the command")], required: ["id"]),
        Tool(name: "krill_sessions_list", description: "List agent and terminal sessions with their status (working, waiting, done, idle, hibernated, exited).", properties: [:], required: []),
        Tool(name: "krill_session_send", description: "Type text into a session's terminal and press Enter (e.g. a prompt for another agent).",
             properties: ["id": prop("string", "Session id"), "text": prop("string", "Text to send")], required: ["id", "text"])
    ]
}
