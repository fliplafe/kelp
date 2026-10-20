import Foundation
import Core

/// `Content-Length` framed JSON-RPC, as LSP speaks over stdio.
public struct LSPFramer: Sendable {
    private var buf = Data()
    public init() {}
    public static func frame(_ body: Data) -> Data { Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body }
    public mutating func append(_ d: Data) -> [Data] {
        buf.append(d)
        var out: [Data] = []
        let sep = Data("\r\n\r\n".utf8)
        while let r = buf.range(of: sep) {
            let header = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
            guard let len = header.split(separator: "\r\n").compactMap({ l -> Int? in
                let p = l.split(separator: ":", maxSplits: 1); return p.count == 2 && p[0].lowercased() == "content-length" ? Int(p[1].trimmingCharacters(in: .whitespaces)) : nil
            }).first else { buf.removeSubrange(buf.startIndex..<r.upperBound); continue }
            guard buf.distance(from: r.upperBound, to: buf.endIndex) >= len else { break }
            let end = buf.index(r.upperBound, offsetBy: len)
            out.append(Data(buf[r.upperBound..<end]))
            buf.removeSubrange(buf.startIndex..<end)
        }
        return out
    }
}

public struct Diagnostic: Sendable, Equatable {
    public var line: Int, column: Int   // 1-based
    public var severity: Int            // 1 error, 2 warning, 3 info, 4 hint
    public var message: String
}

public struct Location: Sendable, Equatable { public var path: String; public var line: Int; public var column: Int }

/// One language server process for one workspace root.
public final class LSPClient: @unchecked Sendable {
    private let proc = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var versions: [String: Int] = [:]
    public let root: String
    public var onDiagnostics: (@Sendable (String, [Diagnostic]) -> Void)?

    /// `argv[0]` is looked up on the login-shell PATH, which the server gets too (npm servers need `node`).
    public init?(argv: [String], root: String) {
        guard let cmd = argv.first, let exe = try? LoginPath.resolve(cmd) else { return nil }
        self.root = root
        proc.executableURL = URL(fileURLWithPath: exe); proc.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment; env["PATH"] = LoginPath.value; proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: root)
        proc.standardInput = input; proc.standardOutput = output; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)   // a server that died fails the write, not the app
        Thread.detachNewThread { [self] in readLoop() }
    }

    deinit { if proc.isRunning { proc.terminate() } }

    private func readLoop() {
        var framer = LSPFramer()
        let h = output.fileHandleForReading
        while true {
            let d = h.availableData
            if d.isEmpty { break }
            for body in framer.append(d) { handle(body) }
        }
        lock.lock(); let all = pending; pending = [:]; lock.unlock()
        all.values.forEach { $0.resume(throwing: RPCError.internalError("language server exited")) }
    }

    private func handle(_ body: Data) {
        guard let m = try? JSONDecoder().decode(RPCMessage.self, from: body) else { return }
        if let method = m.method {
            if method == "textDocument/publishDiagnostics", let p = m.params, let uri = p["uri"]?.string, let path = URL(string: uri)?.path {
                let ds = (p["diagnostics"]?.array ?? []).map { d in
                    Diagnostic(line: (d["range"]?["start"]?["line"]?.int ?? 0) + 1, column: (d["range"]?["start"]?["character"]?.int ?? 0) + 1,
                               severity: d["severity"]?.int ?? 1, message: d["message"]?.string ?? "")
                }
                onDiagnostics?(path, ds)
            } else if let id = m.id {   // server → client request (e.g. workspace/configuration): answer null
                send(["jsonrpc": "2.0", "id": .int(id), "result": .null])
            }
            return
        }
        guard let id = m.id else { return }
        lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
        if let e = m.error { c?.resume(throwing: e) } else { c?.resume(returning: m.result ?? .null) }
    }

    private func send(_ o: [String: JSONValue]) {
        guard let d = try? JSONEncoder().encode(JSONValue.object(o)) else { return }
        try? input.fileHandleForWriting.write(contentsOf: LSPFramer.frame(d))
    }

    public func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { c in
            lock.lock(); let id = nextID; nextID += 1; pending[id] = c; lock.unlock()
            send(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
        }
    }
    public func notify(_ method: String, _ params: JSONValue) { send(["jsonrpc": "2.0", "method": .string(method), "params": params]) }

    public func initialize() async throws {
        let uri = URL(fileURLWithPath: root).absoluteString
        _ = try await request("initialize", .obj([
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)), "rootUri": .string(uri),
            "workspaceFolders": .array([.obj(["uri": .string(uri), "name": .string((root as NSString).lastPathComponent)])]),
            "capabilities": .obj(["textDocument": .obj(["publishDiagnostics": .obj([:]), "definition": .obj([:]), "completion": .obj(["completionItem": .obj(["snippetSupport": false])]),
                                                   "documentSymbol": .obj(["hierarchicalDocumentSymbolSupport": true])])])
        ]))
        notify("initialized", .obj([:]))
    }

    static func uri(_ path: String) -> JSONValue { .string(URL(fileURLWithPath: path).absoluteString) }
    static func pos(_ line: Int, _ col: Int) -> JSONValue { .obj(["line": .int(line - 1), "character": .int(col - 1)]) }

    /// One server can serve several languages (typescript, javascriptreact…), so each file says which it is.
    public func open(_ path: String, text: String, languageId: String) {
        lock.lock(); versions[path] = 1; lock.unlock()
        notify("textDocument/didOpen", .obj(["textDocument": .obj(["uri": Self.uri(path), "languageId": .string(languageId), "version": 1, "text": .string(text)])]))
    }
    public func change(_ path: String, text: String) {
        lock.lock(); let v = (versions[path] ?? 1) + 1; versions[path] = v; lock.unlock()
        notify("textDocument/didChange", .obj(["textDocument": .obj(["uri": Self.uri(path), "version": .int(v)]), "contentChanges": .array([.obj(["text": .string(text)])])]))
    }
    public func close(_ path: String) { notify("textDocument/didClose", .obj(["textDocument": .obj(["uri": Self.uri(path)])])) }

    private func at(_ path: String, _ line: Int, _ col: Int) -> JSONValue { .obj(["textDocument": .obj(["uri": Self.uri(path)]), "position": Self.pos(line, col)]) }

    public func definition(_ path: String, line: Int, column: Int) async throws -> Location? {
        let r = try await request("textDocument/definition", at(path, line, column))
        guard let l = r.array?.first ?? (r == .null ? nil : r) else { return nil }
        let uri = l["uri"]?.string ?? l["targetUri"]?.string
        let range = l["range"] ?? l["targetSelectionRange"]
        guard let uri, let p = URL(string: uri)?.path else { return nil }
        return Location(path: p, line: (range?["start"]?["line"]?.int ?? 0) + 1, column: (range?["start"]?["character"]?.int ?? 0) + 1)
    }

    public func completion(_ path: String, line: Int, column: Int) async throws -> [(label: String, detail: String?, insert: String)] {
        let r = try await request("textDocument/completion", at(path, line, column))
        let items = r.array ?? r["items"]?.array ?? []
        return items.prefix(200).map { ($0["label"]?.string ?? "", $0["detail"]?.string, $0["insertText"]?.string ?? $0["textEdit"]?["newText"]?.string ?? $0["label"]?.string ?? "") }
    }

    /// The innermost function, method, class or module around a 1-based line (the test at the cursor).
    public func symbol(_ path: String, line: Int) async throws -> String? {
        Self.enclosingSymbol(try await request("textDocument/documentSymbol", .obj(["textDocument": .obj(["uri": Self.uri(path)])])), line: line)
    }

    /// From either shape of a documentSymbol result: nested `DocumentSymbol`s or flat `SymbolInformation`s. The smallest
    /// range wins; on a tie the later one (a child is visited after its parent).
    static func enclosingSymbol(_ result: JSONValue, line: Int) -> String? {
        var best: (name: String, span: Int)?
        func visit(_ s: JSONValue) {
            let r = s["range"] ?? s["location"]?["range"]
            if let name = s["name"]?.string, [2, 3, 5, 6, 12, 23].contains(s["kind"]?.int ?? 0),   // module, namespace, class, method, function, struct
               let a = r?["start"]?["line"]?.int, let b = r?["end"]?["line"]?.int, a < line, line - 1 <= b, b - a <= best?.span ?? .max {
                best = (name, b - a)
            }
            s["children"]?.array?.forEach(visit)
        }
        result.array?.forEach(visit)
        return best?.name
    }

    public func shutdown() { Task { _ = try? await request("shutdown", .null); notify("exit", .null) } }
}
