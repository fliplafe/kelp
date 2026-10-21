import Foundation
import os

/// Client for the daemon socket. Requests are async; server notifications go to `onNotification`.
public final class RPCClient: Sendable {
    private let fd: Int32
    private struct State {
        var nextID = 1
        var pending: [Int: CheckedContinuation<Data, Error>] = [:]   // id → its reply line, decoded by the caller as its type
        var closed = false, readerDone = false
        var notificationHandler: (@Sendable (String, JSONValue) -> Void)?
        var closeHandler: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// One line on the wire at a time: a long request written in pieces must not get another one in between. Held across
    /// the write (which can block), so an NSLock rather than the unfair lock above.
    private let writeLock = NSLock()

    /// Read by the reader thread, so kept under the lock like the rest.
    public var onNotification: (@Sendable (String, JSONValue) -> Void)? {
        get { state.withLock { $0.notificationHandler } }
        set { state.withLock { $0.notificationHandler = newValue } }
    }
    /// Set after the connection already dropped, it runs at once: a caller that installs it late is still told.
    public var onClose: (@Sendable () -> Void)? {
        get { state.withLock { $0.closeHandler } }
        set {
            let runNow = state.withLock { s -> Bool in s.closeHandler = newValue; return s.readerDone }
            if runNow { newValue?() }
        }
    }

    public init(socket: String = Paths.socket.path) throws {
        fd = try Unix.connect(socket)
        Thread.detachNewThread { [self] in readLoop() }
    }

    deinit { close() }

    /// Shuts the connection; the reader thread closes the fd when its read returns. Closing it here could let that read
    /// land on a number already reused by a newer connection, and take its replies.
    public func close() {
        // Under writeLock, which the reader takes to close the fd: while we hold it the number is still this connection's.
        writeLock.withLock {
            let skip = state.withLock { s -> Bool in let was = s.closed || s.readerDone; s.closed = true; return was }
            if !skip { shutdown(fd, SHUT_RDWR) }
        }
    }

    private func readLoop() {
        var lb = LineBuffer()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            for line in lb.append(Data(buf[0..<n])) {
                // The result isn't read here: the caller reads it straight from the line, as its own type.
                guard let m = try? JSONDecoder().decode(Envelope.self, from: line) else { continue }
                if let method = m.method {
                    state.withLock { $0.notificationHandler }?(method, m.params ?? .null)
                } else if let id = m.id {
                    let c = state.withLock { $0.pending.removeValue(forKey: id) }
                    if let e = m.error { c?.resume(throwing: e) } else { c?.resume(returning: line) }
                }
            }
        }
        let (all, done) = state.withLock { s in
            defer { s.pending = [:]; s.closed = true; s.readerDone = true }
            return (s.pending, s.closeHandler)
        }
        writeLock.withLock { _ = Darwin.close(fd) }   // the only close: no read or write of ours can follow it
        for (_, c) in all { c.resume(throwing: RPCError.internalError("connection closed")) }
        done?()
    }

    /// Fire-and-forget, written in call order (keystrokes must not overtake each other).
    public func notify(_ method: String, _ params: JSONValue? = nil) {
        guard !state.withLock({ $0.closed }), let d = try? Wire.line(RPCRequest(id: nil, method: method, params: params)) else { return }
        write(d)
    }

    /// Nothing is written once closed: the fd number may be someone else's by then.
    private func write(_ d: Data) { writeLock.withLock { if !state.withLock({ $0.closed }) { Unix.writeAll(fd, d) } } }

    /// `timeout`: throw if no reply came by then — for polls, where one reply that never arrives would stop the loop for good.
    public func call(_ method: String, _ params: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await call(method, params, timeout: timeout, as: JSONValue.self)
    }

    /// The reply's line: a message with `id` and `result` (or `error`, thrown before it gets here).
    private func reply(_ method: String, _ params: JSONValue?, timeout: TimeInterval?) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            let id = state.withLock { s -> Int? in
                guard !s.closed else { return nil }
                defer { s.nextID += 1 }
                s.pending[s.nextID] = c; return s.nextID
            }
            guard let id else { c.resume(throwing: RPCError.internalError("connection closed")); return }
            if let timeout {
                // Weak: every typed call has one now, and a dropped connection's client mustn't wait them out.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.state.withLock { $0.pending.removeValue(forKey: id) }?.resume(throwing: RPCError.internalError("no reply to \(method) in \(Int(timeout)) s"))
                }
            }
            do { write(try Wire.line(RPCRequest(id: id, method: method, params: params))) }
            catch { state.withLock { $0.pending[id] = nil }; c.resume(throwing: error) }
        }
    }

    public func call<T: Decodable>(_ method: String, _ params: JSONValue? = nil, timeout: TimeInterval? = nil, as: T.Type) async throws -> T {
        try JSONDecoder().decode(ResultOf<T>.self, from: await reply(method, params, timeout: timeout)).result
    }

    /// `timeout`: sooner than the method's own (`RPCMethod.timeout`).
    public func call<M: RPCMethod>(_ m: M, timeout: TimeInterval? = nil) async throws -> M.Result {
        try await call(M.name, m.params(), timeout: timeout ?? M.timeout, as: M.Result.self)
    }
    public func notify<M: RPCMethod>(_ m: M) { notify(M.name, try? m.params()) }
}

/// A line from the daemon as far as the reader needs it: a notification's method and params, a reply's id and error.
private struct Envelope: Decodable {
    var id: Int?, method: String?, params: JSONValue?, error: RPCError?
}
/// A reply's result as the caller's type, read from its line in one pass.
private struct ResultOf<R: Decodable>: Decodable { let result: R }

extension JSONValue {
    public static func obj(_ kv: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var d: [String: JSONValue] = [:]; for (k, v) in kv { d[k] = v }; return .object(d)
    }
}
extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral v: Int) { self = .int(v) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral v: Bool) { self = .bool(v) }
}
