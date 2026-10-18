import Foundation

/// JSON-RPC 2.0 messages, newline-delimited over a Unix socket.
public struct RPCRequest: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int?
    public var method: String
    public var params: JSONValue?
    public init(id: Int?, method: String, params: JSONValue? = nil) {
        self.id = id; self.method = method; self.params = params
    }
}

public struct RPCError: Codable, Error, Sendable, Equatable {
    public var code: Int
    public var message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }
    public static func invalidParams(_ m: String) -> RPCError { .init(code: -32602, message: m) }
    public static func internalError(_ m: String) -> RPCError { .init(code: -32603, message: m) }
    public static let methodNotFound = RPCError(code: -32601, message: "method not found")
}

public struct RPCResponse: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int?
    public var result: JSONValue?
    public var error: RPCError?
    /// Server-pushed notifications reuse the request shape; responses carry `id`.
    public init(id: Int?, result: JSONValue? = nil, error: RPCError? = nil) {
        self.id = id; self.result = result; self.error = error
    }
}

/// A line on the wire: either a response (has `result`/`error`) or a notification/request (has `method`).
public struct RPCMessage: Codable, Sendable {
    public var id: Int?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: RPCError?
}

public enum Wire {
    public static func line<T: Encodable>(_ v: T) throws -> Data {
        var d = try JSONEncoder().encode(v)
        d.append(0x0A)
        return d
    }
}

/// Accumulates bytes and yields complete newline-terminated lines.
public struct LineBuffer: Sendable {
    private var buf = Data()
    public init() {}
    public mutating func append(_ d: Data) -> [Data] {
        buf.append(d)
        var out: [Data] = []
        while let i = buf.firstIndex(of: 0x0A) {
            out.append(buf[buf.startIndex..<i])
            buf.removeSubrange(buf.startIndex...i)
        }
        return out
    }
    /// Bytes received after the last complete line (a connection switching to a raw stream keeps them).
    public mutating func takeRemainder() -> Data { defer { buf = Data() }; return buf }
}
