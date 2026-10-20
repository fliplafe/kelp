import Foundation
import Core
import Agents
import GitKit

/// A running PTY plus its history ring buffer, disk log and status detector.
/// The `on…` callbacks are set before `start()` and not changed after.
final class LiveSession: @unchecked Sendable {   // ring, detector, log, discarded under lock; on… callbacks set once before start()
    static let ringLimit = 1 << 20
    /// Past this the log keeps only what the ring holds: a chatty dev server must not fill the disk.
    static let logLimit = 8 << 20

    private let lock = NSLock()
    private(set) var record: Session
    let pty: PTY
    private var ring = Data()
    private var detector: StatusDetector
    private let log: FileHandle?
    private var logSize = 0
    private var logURL: URL?
    private(set) var attached = Set<Int>()   // connection ids receiving raw output
    /// Being deleted: nothing it does may save its record again.
    private var discarded = false
    var isDiscarded: Bool { lock.withLock { discarded } }

    var onOutput: (@Sendable (String, Data, Set<Int>) -> Void)?
    var onStatus: (@Sendable (Session) -> Void)?
    var onFirstPrompt: (@Sendable (String) -> Void)?
    /// The topic the agent keeps in the terminal's title (Claude Code does): a short name for the session.
    var onTopic: (@Sendable (String) -> Void)?
    private var titleCarry = ""
    private var lastTopic: String?
    var topic: String? { lock.withLock { lastTopic } }
    /// What a title that only names the program or its folder contains (TerminalTitle.topic).
    private let selfNames: [String]
    /// First local URL a process prints (dev servers): the app opens it in the worktree's browser.
    var onLocalURL: (@Sendable (String) -> Void)?
    /// Plan usage the agent printed (Claude Code's "used 80% of your weekly limit").
    var onLimits: (@Sendable ([ClaudeLimits.Reading]) -> Void)?
    private var lastLimits: [ClaudeLimits.Reading] = []
    private var sawURL = false
    // swiftlint:disable:next force_try
    static let urlRegex = try! NSRegularExpression(pattern: #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(:\d+)?[^\s\x1b'"]*"#)

    private let started = Date()
    private var transcript: String?
    /// Claude Code transcript (from hook payloads): where its subagents' transcripts live.
    var transcriptPath: String? {
        get { lock.withLock { transcript } }
        set { lock.withLock { transcript = newValue } }
    }
    var idleSeconds: TimeInterval { lock.withLock { Date().timeIntervalSince(lastOutputAt ?? started) } }
    var isAttached: Bool { lock.withLock { !attached.isEmpty } }
    private var lastOutputAt: Date?
    /// TUIs redraw everything after a resize; that output isn't the agent working.
    private var redrawUntil = Date.distantPast
    private var autoAnswers: [(NSRegularExpression, AgentManifest.AutoAnswer)]
    private var pendingPrompt: String?
    /// Someone answered the agent's first question (the user typed, or Kelp's auto-answer pressed its key): from then on
    /// a trust dialog's words left in the scrollback no longer hold the launch prompt back.
    private var dialogSettled = false
    /// The launch prompt is typed but not sent: the user reads it (a hand-off's brief) and presses Return.
    private var promptIsDraft = false
    /// Menu answer in progress: move one step at a time, re-reading the screen, and press Enter only on the wanted option.
    /// `screen`: what must still be on screen for each key (the dialog being answered); nil for a menu the user answers
    /// from a notification.
    private var steering: (choose: NSRegularExpression, since: Date, lastKey: Date, screen: NSRegularExpression?)?
    /// Anything typed into it yet, by the user or by Kelp (a prompt): startup answers are only for what the agent asks
    /// before that. After it, a matching line is something the agent read or wrote, not its own dialog.
    private var typedYet = false
    /// The program turned on bracketed paste (ESC[?2004h): it tells a paste from typing.
    private var pasteMode = false
    private var inputLine = ""
    private var sawFirstPrompt = false
    /// Agents with hooks report their state themselves; the others may through OSC 7501 (ProgramStatus).
    private let hooked: Bool
    private var oscCarry = ""
    private var lastHookAt = Date.distantPast
    /// Esc / ⌃C / an answer while it works or asks: Claude Code sends no hook when a turn is cut short, so the
    /// screen decides ("Interrupted…") within a few seconds. `seen` is the text printed since.
    private var interruptArmed: (at: Date, seen: String)?
    private var compactManual = false
    /// One turn of the agent: the tree when it started working, and what it changed by the time it stopped.
    struct Turn: Codable, Sendable {
        struct File: Codable, Sendable { var path: String; var added: Int; var removed: Int }
        var files: [File]; var seconds: Double
    }
    private(set) var turnBase: String?
    /// Where the agent worked when its last turn started: `turnBase` is a snapshot of that folder.
    private(set) var turnDir: String?
    private var turnStart: Date?
    private(set) var lastTurn: Turn?
    private var inTurn = false
    static let stoppedMarkers = ["Interrupted", "What should Claude do instead", "tell Claude what to do"]

    init(record: Session, manifest: AgentManifest, argv: [String], env: [String: String], historyDir: URL, cols: UInt16, rows: UInt16) throws {
        var rec = record
        detector = StatusDetector(manifest: manifest)
        hooked = manifest.hooksSettingsFlag != nil
        selfNames = [manifest.id, manifest.name, (record.cwd as NSString).lastPathComponent]
        autoAnswers = manifest.autoAnswers.compactMap { a in (try? NSRegularExpression(pattern: a.pattern)).map { ($0, a) } }
        try Paths.ensure(historyDir)
        // A woken session goes on in the same log: what it showed before the pause stays readable.
        let logURL = historyDir.appendingPathComponent("\(record.id).log")
        self.logURL = logURL
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        log = try? FileHandle(forWritingTo: logURL)
        logSize = Int((try? log?.seekToEnd()) ?? 0)
        pty = try PTY(argv: argv, cwd: record.cwd, env: env, cols: cols, rows: rows)
        rec.pid = pty.pid
        self.record = rec
        if logSize > Self.logLimit { trimLogToItsTail() }
        pty.onOutput = { [weak self] d in self?.handleOutput(d) }
        pty.onExit = { [weak self] code in self?.handleExit(code) }
    }

    /// After the callbacks are set: output and status start flowing.
    func start() { pty.start() }

    /// The session is being deleted: it stops, and neither its exit nor anything else saves its record again.
    func discard() { lock.withLock { discarded = true }; pty.kill() }

    /// The log becomes `tail`. Caller holds the lock (or is the initializer).
    /// Keeps the log's own last `ringLimit` bytes, read from the file: after a wake the ring holds only what was printed
    /// since, and trimming to that would drop most of what the session showed before its pause.
    private func trimLogToItsTail() {
        guard let u = logURL, let h = try? FileHandle(forReadingFrom: u) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(max(0, logSize - Self.ringLimit)))
        trimLog((try? h.readToEnd()) ?? Data())
    }

    private func trimLog(_ tail: Data) { try? log?.truncate(atOffset: 0); try? log?.write(contentsOf: tail); logSize = tail.count }

    private func handleOutput(_ d: Data) {
        lock.lock()
        ring.append(d)
        // A copy, at twice the limit: removeFirst on Data only re-slices, and the storage kept every byte the session
        // ever printed (300 MB of output held 300 MB). The slack makes the copy rare.
        if ring.count > 2 * Self.ringLimit { ring = Data(ring.suffix(Self.ringLimit)) }
        try? log?.write(contentsOf: d); logSize += d.count
        if logSize > Self.logLimit { trimLogToItsTail() }
        let text = String(decoding: d, as: UTF8.self)
        var probe = false
        let said = (record.summary, record.progress)
        if !hooked, text.contains(ProgramStatus.prefix) || !oscCarry.isEmpty {
            for m in ProgramStatus.scan(text, carry: &oscCarry) {
                switch m {
                case .query: probe = true
                case .report(let r) where r.id == nil: apply(r)   // children (subagents) aren't shown
                default: break
                }
            }
        }
        if text.contains(ProgramStatus.conEmuPrefix), let p = ProgramStatus.conEmuProgress(text).last { record.progress = p }
        var topic: String?
        if onTopic != nil, text.contains("\u{1B}]") || !titleCarry.isEmpty,
           let t = TerminalTitle.scan(text, carry: &titleCarry).last.flatMap({ TerminalTitle.topic($0, names: selfNames) }), t != lastTopic {
            lastTopic = t; topic = t
        }
        // The chunk without escapes, once, for the two readers that want it.
        let plain = interruptArmed != nil || (!sawURL && onLocalURL != nil) ? StatusDetector.stripANSI(text) : ""
        if let arm = interruptArmed { interruptArmed = (arm.at, String((arm.seen + plain).suffix(4000))) }
        if Date() > redrawUntil { detector.output(text); lastOutputAt = Date() }
        if let on = text.range(of: "\u{1B}[?2004", options: .backwards), let mode = text[on.upperBound...].first { pasteMode = mode == "h" }
        var answer: String?
        if !autoAnswers.isEmpty, !typedYet, Date().timeIntervalSince(started) < 90 {
            let tail = StatusDetector.stripANSI(String(decoding: ring.suffix(4000), as: UTF8.self))
            let r = NSRange(tail.startIndex..., in: tail)
            if let i = autoAnswers.firstIndex(where: { $0.0.firstMatch(in: tail, range: r) != nil }) {
                let a = autoAnswers[i].1
                if let choose = a.choose, let re = try? NSRegularExpression(pattern: choose) {
                    steering = (re, Date(), .distantPast, autoAnswers[i].0); autoAnswers.remove(at: i)   // closed loop, see steer()
                } else { answer = a.input; autoAnswers.remove(at: i); dialogSettled = true }
            }
        }
        var url: String?
        if !sawURL, onLocalURL != nil {
            if let m = Self.urlRegex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)), let r = Range(m.range, in: plain) {
                sawURL = true; url = String(plain[r]).replacingOccurrences(of: "0.0.0.0", with: "localhost").replacingOccurrences(of: "[::]", with: "localhost")
            }
        }
        var limits: [ClaudeLimits.Reading] = []
        if onLimits != nil, text.contains("limit") {
            let found = ClaudeLimits.parse(StatusDetector.stripANSI(String(decoding: ring.suffix(1200), as: UTF8.self)))
            if !found.isEmpty, found != lastLimits { lastLimits = found; limits = found }
        }
        let subs = attached, sid = record.id   // read under the lock: other threads write `record`
        let changed = sync() ?? (said != (record.summary, record.progress) ? record : nil)
        lock.unlock()
        if probe { pty.write(Data(ProgramStatus.queryReply.utf8)) }   // "I read OSC 7501": the agent starts reporting
        if !limits.isEmpty { onLimits?(limits) }
        if let url { onLocalURL?(url) }
        if let topic { onTopic?(topic) }
        if let answer { DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pty.write(Data(answer.utf8)) } }
        onOutput?(sid, d, subs)
        if let changed { onStatus?(changed) }
    }

    private func handleExit(_ code: Int32) {
        lock.lock()
        if record.status == .hibernated { try? log?.close(); lock.unlock(); return }
        detector.exited()
        let exitCode = (code & 0x7f) == 0 ? (code >> 8) & 0xff : 0   // killed by a signal (closed, stopped) isn't a failure
        if exitCode != 0, record.agent != "shell" { record.summary = "Ended with an error (exit code \(exitCode))" }
        record.progress = nil; record.exitCode = Int((code & 0x7f) == 0 ? (code >> 8) & 0xff : 128 + (code & 0x7f))
        let changed = sync()
        try? log?.close()
        lock.unlock()
        if let changed { onStatus?(changed) }
    }

    /// What the program says about itself (OSC 7501 or `kelp report`): its state, a message for its row, how far it got.
    /// Caller holds the lock.
    private func apply(_ r: ProgramStatus.Report) {
        detector.program(r.state); lastHookAt = Date()
        if let msg = r.msg, !msg.isEmpty { record.summary = msg } else if r.state == "idle" || r.state == "clear" { record.summary = "" }
        record.progress = r.progress
    }

    /// `kelp report`: the record to publish when only what it says changed (a new state goes out through onStatus).
    func report(_ r: ProgramStatus.Report) -> Session? {
        lock.lock(); apply(r); let c = sync(), rec = record; lock.unlock()
        if let c { onStatus?(c); return nil }
        return rec
    }

    /// Copy detector status into the record. Caller holds the lock. Returns the record if it changed.
    /// Ended is final: a hook or a keystroke that arrives after the exit doesn't bring the session back.
    private func sync() -> Session? {
        let s = detector.status
        guard s != record.status, record.status != .exited else { return nil }
        record.status = s
        if s == .done || s == .waiting || s == .exited || s == .error { record.unread = true }
        return record
    }

    /// Called with every status change: a snapshot when work starts, the changes when it stops (git work off the lock).
    func noteTurn(_ s: AgentStatus) {
        lock.lock()
        let shell = record.agent == "shell"
        let starting = s == .working && !inTurn, ending = inTurn && s != .working
        if starting { inTurn = true; turnStart = Date(); turnDir = record.currentDir }
        if ending { inTurn = false }
        let start = turnStart, cwd = turnDir ?? record.cwd
        lock.unlock()
        guard !shell, starting || ending else { return }
        // One after another, per session: a short turn's end waits for its own start snapshot instead of diffing against
        // the previous turn's (which credited it with that turn's changes), and snapshots can't land out of order.
        turnWork.async { [weak self] in
            if starting {
                let tree = try? Git.snapshotTree(cwd)
                self?.lock.withLock { self?.turnBase = tree }
            } else if let start, let base = self?.lock.withLock({ self?.turnBase }) {
                let files = ((try? Git.changesSince(tree: base, cwd: cwd)) ?? []).map { Turn.File(path: $0.path, added: $0.added, removed: $0.removed) }
                self?.lock.withLock { self?.lastTurn = Turn(files: files, seconds: Date().timeIntervalSince(start)) }
            }
        }
    }
    private let turnWork = DispatchQueue(label: "kelp.session.turn", qos: .utility)

    func tick() {
        steer()
        lock.lock(); detector.tick()
        if let arm = interruptArmed {
            if lastHookAt > arm.at { interruptArmed = nil }
            else if Self.stoppedMarkers.contains(where: arm.seen.contains) {
                detector.override(.idle); record.summary = "Stopped by you"; interruptArmed = nil
            } else if Date().timeIntervalSince(arm.at) > 10 { interruptArmed = nil }
        }
        let c = sync()
        // Deliver the launch prompt once the TUI has drawn and gone quiet (or after a timeout).
        var prompt: String?
        // Never while a trust question is open: its Enter would be the prompt's, and "Yes" is the default. Kelp leaves that
        // question to the user on purpose (an untrusted project, a branch that changes agent config); the prompt waits.
        if let p = pendingPrompt, steering == nil, !trustQuestionOpen() {
            let quiet = lastOutputAt.map { Date().timeIntervalSince($0) > 1.5 } ?? false
            if (quiet && Date().timeIntervalSince(started) > 2) || Date().timeIntervalSince(started) > 25 { prompt = p; pendingPrompt = nil }
        }
        lock.unlock()
        if let c { onStatus?(c) }
        if let prompt { send(prompt, enter: !lock.withLock { promptIsDraft }, paste: true) }   // a task's text: never keys
    }

    /// Caller holds the lock.
    private func trustQuestionOpen() -> Bool {
        guard !dialogSettled else { return false }
        let tail = StatusDetector.stripANSI(String(decoding: ring.suffix(4000), as: UTF8.self))
        return Self.trustQuestion?.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
    }
    private static let trustQuestion = try? NSRegularExpression(pattern: AgentManifest.trust.pattern)

    /// Called on every tick. Reads the latest menu render; Enter only when the cursor sits on the wanted option.
    private func steer() {
        lock.lock()
        guard let st = steering else { lock.unlock(); return }
        if Date().timeIntervalSince(st.since) > 30 { steering = nil; lock.unlock(); return }
        guard Date().timeIntervalSince(st.lastKey) > 0.7 else { lock.unlock(); return }
        let screen = StatusDetector.stripANSI(String(decoding: ring.suffix(1500), as: UTF8.self))
        // The dialog it was armed for has to be the one on screen, at every key: another menu is never pressed.
        if let must = st.screen, must.firstMatch(in: screen, range: NSRange(screen.startIndex..., in: screen)) == nil || typedYet {
            steering = nil; lock.unlock(); return
        }
        guard let option = AgentManifest.AutoAnswer.optionAtCursor(screen) else { lock.unlock(); return }
        let onTarget = st.choose.firstMatch(in: option, range: NSRange(option.startIndex..., in: option)) != nil
        let key: String
        if onTarget { key = "\r"; steering = nil; dialogSettled = true }
        else { key = "\u{1B}[B"; steering?.lastKey = Date() }   // menus wrap, so stepping down always reaches it
        lock.unlock()
        pty.write(Data(key.utf8))
    }

    /// Answers the menu the agent shows (a permission request) from outside the terminal — a notification's Allow / Deny.
    /// The cursor is walked to the option and Enter pressed only there (see `steer`). nil: no such menu on screen.
    func choose(_ answer: String) -> Session? {
        lock.lock()
        let screen = StatusDetector.stripANSI(String(decoding: ring.suffix(1500), as: UTF8.self))
        let pattern = answer == "allow" ? #"^(\d+\.\s*)?(Yes|Allow|Approve)\b(?!,)"# : #"^(\d+\.\s*)?(No|Deny|Reject)\b"#
        let lines = screen.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ❯›>")) }
        guard AgentManifest.AutoAnswer.optionAtCursor(screen) != nil, let re = try? NSRegularExpression(pattern: pattern),
              lines.contains(where: { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) else { lock.unlock(); return nil }
        steering = (re, Date(), .distantPast, nil)
        detector.input(); record.unread = false
        if hooked { detector.override(.working); interruptArmed = (Date(), "") }   // a "No" ends the turn: the screen says so
        let changed = sync() ?? record
        lock.unlock()
        return changed
    }

    func resize(cols: UInt16, rows: UInt16) {
        lock.withLock { redrawUntil = Date().addingTimeInterval(1) }
        pty.resize(cols: cols, rows: rows)
    }

    func queuePrompt(_ p: String, draft: Bool = false) { lock.lock(); pendingPrompt = p; promptIsDraft = draft; sawFirstPrompt = true; lock.unlock() }

    /// Type text into the agent. Multi-line text goes as a bracketed paste so TUIs don't submit each line.
    /// `paste`: as a paste even on one line (when the program takes pastes), so a leading "!" or "/" (an issue title) is
    /// text, not a mode or command.
    /// Without it one line is typed, so `kelp send <id> /compact` still runs the command.
    func send(_ text: String, enter: Bool, paste: Bool = false) {
        let pasteMode = lock.withLock { detector.input(); typedYet = true; return pasteMode }
        let text = Self.typeable(text)
        // A program that never asked for pastes (a plain line reader) has no modes to trip: it gets the text as is.
        let body = (paste && pasteMode) || text.contains("\n") ? "\u{1B}[200~" + text + "\u{1B}[201~" : text
        // One after another, Enter included: two quick sends must arrive as text, Enter, text, Enter, not text, text, Enter, Enter.
        sends.async { [weak self] in
            self?.pty.write(Data(body.utf8))
            if enter { Thread.sleep(forTimeInterval: 0.3); self?.pty.write(Data("\r".utf8)) }
        }
    }
    private let sends = DispatchQueue(label: "kelp.session.send")

    /// Text from elsewhere (an issue, a recipe, a review comment) as plain text: no escape sequences and no control keys but
    /// newlines and tabs. An issue body with ESC[201~ would end the paste, then Return, Shift-Tab or "!cmd" would act as keys.
    static func typeable(_ s: String) -> String {
        String(String.UnicodeScalarView(s.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter { c in
            c == "\n" || c == "\t" || !(c.value < 0x20 || c.value == 0x7F || (0x80...0x9F).contains(c.value))
        }))
    }

    /// Keystrokes from a UI: the first submitted line becomes the source of the tab title.
    func userInput(_ d: Data) {
        pty.write(d)
        lock.lock()
        guard !TerminalReplies.isReply(d) else { lock.unlock(); return }   // the terminal answering the agent, not the user typing
        typedYet = true; dialogSettled = true
        detector.input(typing: !d.contains(0x0D))   // keys without Return: the prompt is still being written
        var read: Session?
        if record.unread { record.unread = false; read = record }   // typing into it is having read it
        if hooked {
            if d == Data([0x1B]) || d.contains(0x03), record.status == .working || record.status == .waiting { interruptArmed = (Date(), "") }
            // An answer to a question or a permission menu: it works again (Claude Code sends no hook for that).
            if record.status == .waiting, d.contains(0x0D) || (d.count == 1 && (0x31...0x39).contains(d[0])) {
                detector.override(.working); interruptArmed = (Date(), "")
            }
        }
        let changed = sync() ?? read
        lock.unlock()
        if let changed { onStatus?(changed) }
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

    /// `trigger`: PreCompact's manual / auto; `message`: what a Notification says ("Claude needs your permission to use Bash").
    func hook(_ event: String, trigger: String? = nil, message: String? = nil) {
        lock.lock()
        lastHookAt = Date()
        let compacting = "Compacting the conversation…"
        switch event {
        case "compacting":
            compactManual = trigger == "manual"; record.summary = compacting; detector.hook("working")
        case "compacted":
            if record.summary == compacting { record.summary = "" }
            if compactManual { detector.override(.idle) }   // /compact finished: back at the prompt; an auto one carries on
        case "waiting":
            if let message, !message.isEmpty { record.summary = message }
            detector.hook(event)
        default: detector.hook(event)
        }
        let c = sync(); lock.unlock()
        if let c { onStatus?(c) }
    }

    /// A hook's `cwd`: where the agent works now. The record when that changed.
    func workIn(_ dir: String) -> Session? {
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path }
        lock.lock(); defer { lock.unlock() }
        let w = real(dir) == real(record.cwd) ? nil : dir
        guard w != record.workDir else { return nil }
        record.workDir = w; return record
    }

    func markRead() -> Session? {
        lock.lock(); defer { lock.unlock() }
        guard record.unread else { return nil }
        record.unread = false; return record
    }

    func markUnread() -> Session? {
        lock.lock(); defer { lock.unlock() }
        guard !record.unread else { return nil }
        record.unread = true; return record
    }

    func tail(_ n: Int) -> Data { lock.lock(); defer { lock.unlock() }; return ring.suffix(min(max(0, n), Self.ringLimit)) }
    /// The history, `conn` gets the output from here on. `send` runs under the lock with that history, so it goes out
    /// before any of the live output that follows.
    @discardableResult
    func attach(_ conn: Int, send: (Data) -> Void = { _ in }) -> Data {
        lock.lock(); defer { lock.unlock() }
        attached.insert(conn)
        let history = TerminalReplies.withoutQueries(ring.suffix(Self.ringLimit)); send(history); return history
    }
    func detach(_ conn: Int) { lock.lock(); attached.remove(conn); lock.unlock() }
    var snapshot: Session { lock.lock(); defer { lock.unlock() }; return record }
}
