import Foundation

/// KRILL_PERF=1: prints how long named steps take (finding what makes the UI stall).
enum Perf {
    static let on = ProcessInfo.processInfo.environment["KRILL_PERF"] != nil
    @discardableResult
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        guard on else { return try work() }
        let t0 = Date()
        defer { print(String(format: "PERF %@ %.0f ms", name, Date().timeIntervalSince(t0) * 1000)) }
        return try work()
    }
}
