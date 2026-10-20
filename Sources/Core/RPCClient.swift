import Foundation

/// Client for the daemon socket. Requests are async; server notifications go to `onNotification`.
public final class RPCClient: @unchecked Sendable {   // mutable state (nextID, pending, closed) under lock; writes under writeLock
    private let fd: Int32
    private let lock = NSLock()
    /// One line on the wire at a time: a long request written in pieces must not get another one in between.
    private let writeLock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false
    private var notificationHandler: (@Sendable (String, JSONValue) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var readerDone = false

    /// Read by the reader thread, so kept under the lock like the rest.
    public var onNotification: (@Sendable (String, JSONValue) -> Void)? {
        get { lock.withLock { notificationHandler } }
        set { lock.withLock { notificationHandler = newValue } }
    }
    /// Set after the connection already dropped, it runs at once: a caller that installs it late is still told.
    public var onClose: (@Sendable () -> Void)? {
        get { lock.withLock { closeHandler } }
        set {
            let runNow = lock.withLock { () -> Bool in closeHandler = newValue; return readerDone }
            if runNow { newValue?() }
        }
    }

    public init(socket: String = Paths.socket.path) throws {
        fd = try Unix.connect(socket)
        Thread.detachNewThread { [self] in readLoop() }
    }

    deinit { close() }

    public func close() {
        lock.lock(); let was = closed; closed = true; lock.unlock()
        if !was { shutdown(fd, SHUT_RDWR); writeLock.withLock { _ = Darwin.close(fd) } }
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
                    lock.withLock { notificationHandler }?(method, m.params ?? .null)
                } else if let id = m.id {
                    lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
                    if let e = m.error { c?.resume(throwing: e) } else { c?.resume(returning: m.result ?? .null) }
                }
            }
        }
        lock.lock(); let all = pending; pending = [:]; closed = true; readerDone = true; let done = closeHandler; lock.unlock()
        for (_, c) in all { c.resume(throwing: RPCError.internalError("connection closed")) }
        done?()
    }

    /// Fire-and-forget, written in call order (keystrokes must not overtake each other).
    public func notify(_ method: String, _ params: JSONValue? = nil) {
        guard !lock.withLock({ closed }), let d = try? Wire.line(RPCRequest(id: nil, method: method, params: params)) else { return }
        write(d)
    }

    /// Nothing is written once closed: the fd number may be someone else's by then.
    private func write(_ d: Data) { writeLock.withLock { if !lock.withLock({ closed }) { Unix.writeAll(fd, d) } } }

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
            do { write(try Wire.line(RPCRequest(id: id, method: method, params: params))) }
            catch { lock.lock(); pending[id] = nil; lock.unlock(); c.resume(throwing: error) }
        }
    }

    public func call<T: Decodable>(_ method: String, _ params: JSONValue? = nil, as: T.Type) async throws -> T {
        try await call(method, params).decode(T.self)
    }

    public func call<M: RPCMethod>(_ m: M) async throws -> M.Result {
        try await call(M.name, m.params()).decode(M.Result.self)
    }
    public func notify<M: RPCMethod>(_ m: M) { notify(M.name, try? m.params()) }
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
