import Foundation

/// Client for the daemon socket. Requests are async; server notifications go to `onNotification`.
public final class RPCClient: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false
    public var onNotification: (@Sendable (String, JSONValue) -> Void)?
    public var onClose: (@Sendable () -> Void)?

    public init(socket: String = Paths.socket.path) throws {
        fd = try Unix.connect(socket)
        Thread.detachNewThread { [self] in readLoop() }
    }

    deinit { close() }

    public func close() {
        lock.lock(); let was = closed; closed = true; lock.unlock()
        if !was { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
    }

    private func readLoop() {
        var lb = LineBuffer()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            for line in lb.append(Data(buf[0..<n])) {
                guard let m = try? JSONDecoder().decode(RPCMessage.self, from: line) else { continue }
                if let method = m.method {
                    onNotification?(method, m.params ?? .null)
                } else if let id = m.id {
                    lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
                    if let e = m.error { c?.resume(throwing: e) } else { c?.resume(returning: m.result ?? .null) }
                }
            }
        }
        lock.lock(); let all = pending; pending = [:]; closed = true; lock.unlock()
        for (_, c) in all { c.resume(throwing: RPCError.internalError("connection closed")) }
        onClose?()
    }

    /// Fire-and-forget, written in call order (keystrokes must not overtake each other).
    public func notify(_ method: String, _ params: JSONValue? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let d = try? Wire.line(RPCRequest(id: nil, method: method, params: params)) else { return }
        Unix.writeAll(fd, d)
    }

    /// `timeout`: throw if no reply came by then — for polls, where one reply that never arrives would stop the loop for good.
    public func call(_ method: String, _ params: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if closed { lock.unlock(); c.resume(throwing: RPCError.internalError("connection closed")); return }
            let id = nextID; nextID += 1; pending[id] = c
            lock.unlock()
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                    lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
                    c?.resume(throwing: RPCError.internalError("no reply to \(method) in \(Int(timeout)) s"))
                }
            }
            do { Unix.writeAll(fd, try Wire.line(RPCRequest(id: id, method: method, params: params))) }
            catch { lock.lock(); pending[id] = nil; lock.unlock(); c.resume(throwing: error) }
        }
    }

    public func call<T: Decodable>(_ method: String, _ params: JSONValue? = nil, as: T.Type) async throws -> T {
        try await call(method, params).decode(T.self)
    }
}

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
