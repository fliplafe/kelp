import Foundation
import Core
import Agents

/// A running PTY plus its history ring buffer, disk log and status detector.
final class LiveSession: @unchecked Sendable {
    static let ringLimit = 1 << 20

    private let lock = NSLock()
    private(set) var record: Session
    let pty: PTY
    private var ring = Data()
    private var detector: StatusDetector
    private let log: FileHandle?
    private(set) var attached = Set<Int>()   // connection ids receiving raw output

    var onOutput: (@Sendable (String, Data, Set<Int>) -> Void)?
    var onStatus: (@Sendable (Session) -> Void)?

    init(record: Session, manifest: AgentManifest, argv: [String], env: [String: String], historyDir: URL, cols: UInt16, rows: UInt16) throws {
        var rec = record
        detector = StatusDetector(manifest: manifest)
        try Paths.ensure(historyDir)
        let logURL = historyDir.appendingPathComponent("\(record.id).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try? FileHandle(forWritingTo: logURL)
        pty = try PTY(argv: argv, cwd: record.cwd, env: env, cols: cols, rows: rows)
        rec.pid = pty.pid
        self.record = rec
        pty.onOutput = { [weak self] d in self?.handleOutput(d) }
        pty.onExit = { [weak self] code in self?.handleExit(code) }
    }

    private func handleOutput(_ d: Data) {
        lock.lock()
        ring.append(d)
        if ring.count > Self.ringLimit { ring.removeFirst(ring.count - Self.ringLimit) }
        try? log?.write(contentsOf: d)
        detector.output(String(decoding: d, as: UTF8.self))
        let subs = attached
        let changed = sync()
        lock.unlock()
        onOutput?(record.id, d, subs)
        if let changed { onStatus?(changed) }
    }

    private func handleExit(_ code: Int32) {
        lock.lock()
        detector.exited()
        let changed = sync()
        try? log?.close()
        lock.unlock()
        if let changed { onStatus?(changed) }
    }

    /// Copy detector status into the record. Caller holds the lock. Returns the record if it changed.
    private func sync() -> Session? {
        let s = detector.status
        guard s != record.status else { return nil }
        record.status = s
        if s == .done || s == .waiting || s == .exited { record.unread = true }
        return record
    }

    func tick() {
        lock.lock(); detector.tick(); let c = sync(); lock.unlock()
        if let c { onStatus?(c) }
    }

    func hook(_ event: String) {
        lock.lock(); detector.hook(event); let c = sync(); lock.unlock()
        if let c { onStatus?(c) }
    }

    func markRead() -> Session? {
        lock.lock(); defer { lock.unlock() }
        guard record.unread else { return nil }
        record.unread = false; return record
    }

    func tail(_ n: Int) -> Data { lock.lock(); defer { lock.unlock() }; return ring.suffix(n) }
    func attach(_ conn: Int) -> Data { lock.lock(); defer { lock.unlock() }; attached.insert(conn); return ring }
    func detach(_ conn: Int) { lock.lock(); attached.remove(conn); lock.unlock() }
    var snapshot: Session { lock.lock(); defer { lock.unlock() }; return record }
}
