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

/// A line on the wire: either a response (has `result`/`error`) or a notification/request (has `method`).
public struct RPCMessage: Codable, Sendable {
    public var id: Int?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: RPCError?
}

/// A method declared as a type (Methods.swift), shared by the app, the CLI and the daemon like Zed's proto messages:
/// a misspelled key or a wrong result shape doesn't compile. Its fields are the request's params, exactly the JSON
/// the method takes when written by hand, so untyped callers (older apps, scripts) keep working.
public protocol RPCMethod: Codable, Sendable {
    associatedtype Result: Codable & Sendable
    static var name: String { get }
}

extension RPCMethod {
    /// The request's params: the fields, or none for a method without any (as hand-written calls send it).
    public func params() throws -> JSONValue? {
        let p = try JSONValue.from(self)
        return p == .object([:]) ? nil : p
    }
}

/// The result of a method that answers null.
public struct Done: Codable, Sendable {
    public init() {}
    public init(from decoder: Decoder) {}
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encodeNil() }
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
    /// Only the new bytes are searched and the consumed lines dropped once: a multi-MB reply arrives in 8 KB reads,
    /// and rescanning (and shifting) the whole buffer on each one was quadratic.
    public mutating func append(_ d: Data) -> [Data] {
        var from = buf.endIndex   // the bytes already here hold no newline
        buf.append(d)
        var out: [Data] = [], start = buf.startIndex
        while let i = buf[from...].firstIndex(of: 0x0A) { out.append(buf[start..<i]); start = i + 1; from = start }
        if start != buf.startIndex { buf = Data(buf[start...]) }
        return out
    }
    /// Bytes received after the last complete line (a connection switching to a raw stream keeps them).
    public mutating func takeRemainder() -> Data { defer { buf = Data() }; return buf }
}
