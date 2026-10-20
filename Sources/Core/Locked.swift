import Foundation

/// A value reachable only under its lock. The one type that vouches for Sendable by hand: classes that share state across
/// threads keep it in one of these and are then checked by the compiler, instead of each pairing an NSLock with vars by
/// convention (and a comment saying which lock guards what).
public final class Locked<Value: Sendable>: @unchecked Sendable {   // value under lock, never handed out by reference
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }

    /// Reads or changes the value; nothing else touches it meanwhile.
    @discardableResult
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R { try lock.withLock { try body(&value) } }

    public var current: Value { lock.withLock { value } }
}
