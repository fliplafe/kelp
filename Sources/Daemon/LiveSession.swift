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
    var onFirstPrompt: (@Sendable (String) -> Void)?
    /// First local URL a process prints (dev servers): the app opens it in the worktree's browser.
    var onLocalURL: (@Sendable (String) -> Void)?
    private var sawURL = false
    // swiftlint:disable:next force_try
    static let urlRegex = try! NSRegularExpression(pattern: #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(:\d+)?[^\s\x1b'"]*"#)

    private let started = Date()
    /// Claude Code transcript (from hook payloads): where its subagents' transcripts live.
    var transcriptPath: String?
    var idleSeconds: TimeInterval { lock.withLock { Date().timeIntervalSince(lastOutputAt ?? started) } }
    var isAttached: Bool { lock.withLock { !attached.isEmpty } }
    private var lastOutputAt: Date?
    private var autoAnswers: [(NSRegularExpression, AgentManifest.AutoAnswer)]
    private var pendingPrompt: String?
    /// Menu answer in progress: move one step at a time, re-reading the screen, and press Enter only on the wanted option.
    private var steering: (choose: NSRegularExpression, since: Date, lastKey: Date)?
    private var inputLine = ""
    private var sawFirstPrompt = false

    init(record: Session, manifest: AgentManifest, argv: [String], env: [String: String], historyDir: URL, cols: UInt16, rows: UInt16) throws {
        var rec = record
        detector = StatusDetector(manifest: manifest)
        autoAnswers = manifest.autoAnswers.compactMap { a in (try? NSRegularExpression(pattern: a.pattern)).map { ($0, a) } }
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
        let text = String(decoding: d, as: UTF8.self)
        detector.output(text)
        lastOutputAt = Date()
        var answer: String?
        if !autoAnswers.isEmpty, Date().timeIntervalSince(started) < 90 {
            let tail = StatusDetector.stripANSI(String(decoding: ring.suffix(4000), as: UTF8.self))
            let r = NSRange(tail.startIndex..., in: tail)
            if let i = autoAnswers.firstIndex(where: { $0.0.firstMatch(in: tail, range: r) != nil }) {
                let a = autoAnswers[i].1
                if let choose = a.choose, let re = try? NSRegularExpression(pattern: choose) {
                    steering = (re, Date(), .distantPast); autoAnswers.remove(at: i)   // closed loop, see steer()
                } else { answer = a.input; autoAnswers.remove(at: i) }
            }
        }
        var url: String?
        if !sawURL, onLocalURL != nil {
            let plain = StatusDetector.stripANSI(text)
            if let m = Self.urlRegex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)), let r = Range(m.range, in: plain) {
                sawURL = true; url = String(plain[r]).replacingOccurrences(of: "0.0.0.0", with: "localhost").replacingOccurrences(of: "[::]", with: "localhost")
            }
        }
        let subs = attached
        let changed = sync()
        lock.unlock()
        if let url { onLocalURL?(url) }
        if let answer { DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pty.write(Data(answer.utf8)) } }
        onOutput?(record.id, d, subs)
        if let changed { onStatus?(changed) }
    }

    private func handleExit(_ code: Int32) {
        lock.lock()
        if record.status == .hibernated { try? log?.close(); lock.unlock(); return }
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
        steer()
        lock.lock(); detector.tick(); let c = sync()
        // Deliver the launch prompt once the TUI has drawn and gone quiet (or after a timeout).
        var prompt: String?
        if let p = pendingPrompt {
            let quiet = lastOutputAt.map { Date().timeIntervalSince($0) > 1.5 } ?? false
            if (quiet && Date().timeIntervalSince(started) > 2) || Date().timeIntervalSince(started) > 25 { prompt = p; pendingPrompt = nil }
        }
        lock.unlock()
        if let c { onStatus?(c) }
        if let prompt { send(prompt, enter: true) }
    }

    /// Called on every tick. Reads the latest menu render; Enter only when the cursor sits on the wanted option.
    private func steer() {
        lock.lock()
        guard let st = steering else { lock.unlock(); return }
        if Date().timeIntervalSince(st.since) > 30 { steering = nil; lock.unlock(); return }
        guard Date().timeIntervalSince(st.lastKey) > 0.7 else { lock.unlock(); return }
        let screen = StatusDetector.stripANSI(String(decoding: ring.suffix(1500), as: UTF8.self))
        guard let option = AgentManifest.AutoAnswer.optionAtCursor(screen) else { lock.unlock(); return }
        let onTarget = st.choose.firstMatch(in: option, range: NSRange(option.startIndex..., in: option)) != nil
        let key: String
        if onTarget { key = "\r"; steering = nil }
        else { key = "\u{1B}[B"; steering?.lastKey = Date() }   // menus wrap, so stepping down always reaches it
        lock.unlock()
        pty.write(Data(key.utf8))
    }

    func queuePrompt(_ p: String) { lock.lock(); pendingPrompt = p; sawFirstPrompt = true; lock.unlock() }

    /// Type text into the agent. Multi-line text goes as a bracketed paste so TUIs don't submit each line.
    func send(_ text: String, enter: Bool) {
        let body = text.contains("\n") ? "\u{1B}[200~" + text + "\u{1B}[201~" : text
        pty.write(Data(body.utf8))
        if enter { DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.pty.write(Data("\r".utf8)) } }
    }

    /// Keystrokes from a UI: the first submitted line becomes the source of the tab title.
    func userInput(_ d: Data) {
        pty.write(d)
        lock.lock(); defer { lock.unlock() }
        guard !sawFirstPrompt else { return }
        var s = String(decoding: d, as: UTF8.self)
        if s.hasPrefix("\u{1B}[200~") { s = s.replacingOccurrences(of: "\u{1B}[200~", with: "").replacingOccurrences(of: "\u{1B}[201~", with: "") }
        else if s.hasPrefix("\u{1B}") { return }   // arrows, function keys
        for ch in s {
            switch ch {
            case "\r", "\n":
                let line = inputLine.trimmingCharacters(in: .whitespaces); inputLine = ""
                if line.count >= 8 { sawFirstPrompt = true; let cb = onFirstPrompt; DispatchQueue.global().async { cb?(line) } }
            case "\u{7F}", "\u{08}": if !inputLine.isEmpty { inputLine.removeLast() }
            default: if !ch.isASCII || ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol || ch == " " { inputLine.append(ch) }
            }
        }
    }

    func update(_ f: (inout Session) -> Void) -> Session {
        lock.lock(); f(&record); let r = record; lock.unlock(); return r
    }

    /// Hibernation: the PTY dies but the record says so, so the UI shows "Paused" instead of "Exited".
    func markHibernated() -> Session {
        lock.lock(); detector.override(.hibernated); record.status = .hibernated; let r = record; lock.unlock(); return r
    }

    func overrideStatus(_ s: AgentStatus) {
        lock.lock(); detector.override(s); let c = sync(); lock.unlock()
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
