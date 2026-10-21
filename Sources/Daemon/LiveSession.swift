import Foundation
import os
import Core
import Agents
import GitKit

/// A running PTY plus its history ring buffer, disk log and status detector.
/// Everything that changes is in `state`, read and written only inside `state.withLock`; what it calls out to (the
/// daemon's callbacks, sends to clients) runs after the lock, or is queued under it where order matters (`emit`).
final class LiveSession: Sendable {
    static let ringLimit = 1 << 20
    /// Past this the log keeps only what the ring holds: a chatty dev server must not fill the disk.
    static let logLimit = 8 << 20

    /// What the daemon hears from it, fixed before the program starts.
    struct Callbacks: Sendable {
        /// Raw output, for the connections attached at that moment.
        var output: @Sendable (_ session: String, _ data: Data, _ attached: Set<Int>) -> Void = { _, _, _ in }
        /// A changed record, in the order the changes were made (`emit`).
        var status: @Sendable (LiveSession, Session) -> Void = { _, _ in }
        var firstPrompt: @Sendable (String) -> Void = { _ in }
        /// The topic the agent keeps in the terminal's title (Claude Code does): a short name for the session.
        var topic: (@Sendable (String) -> Void)?
        /// First local URL a process prints (dev servers): the app opens it in the worktree's browser.
        var localURL: (@Sendable (String) -> Void)?
        /// Plan usage the agent printed (Claude Code's "used 80% of your weekly limit").
        var limits: (@Sendable ([ClaudeLimits.Reading]) -> Void)?
    }

    let pty: PTY
    let callbacks: Callbacks
    let state: OSAllocatedUnfairLock<State>
    private let log: FileHandle?
    private let logURL: URL
    /// Text typed in order, Enter included (see `type`).
    let sends = DispatchQueue(label: "kelp.session.send")
    private let statusQueue = DispatchQueue(label: "kelp.session.status")
    private let turnWork = DispatchQueue(label: "kelp.session.turn", qos: .utility)
    // swiftlint:disable:next force_try
    static let urlRegex = try! NSRegularExpression(pattern: #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(:\d+)?[^\s\x1b'"]*"#)
    static let stoppedMarkers = ["Interrupted", "What should Claude do instead", "tell Claude what to do"]

    /// One turn of the agent: the tree when it started working, and what it changed by the time it stopped.
    struct Turn: Codable, Sendable {
        struct File: Codable, Sendable { var path: String; var added: Int; var removed: Int }
        var files: [File]; var seconds: Double
    }

    /// Esc or ⌃C, as one byte or as the kitty keyboard protocol sends them once the agent turns it on (Claude Code does):
    /// ESC[27u, ESC[99;5u — on a non-Latin layout the layout's own letter comes first (ESC[1089::99;5u).
    static func isStopKey(_ d: Data) -> Bool {
        d == Data([0x1B]) || d.contains(0x03) || String(decoding: d, as: UTF8.self).wholeMatch(of: /\x1B\[(27|([0-9]*:)*99;5)u/) != nil
    }

    init(record: Session, manifest: AgentManifest, argv: [String], env: [String: String], historyDir: URL, cols: UInt16, rows: UInt16,
         callbacks: Callbacks) throws {
        var rec = record
        try Paths.ensure(historyDir)
        // A woken session goes on in the same log: what it showed before the pause stays readable.
        logURL = historyDir.appendingPathComponent("\(record.id).log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        do { log = try FileHandle(forWritingTo: logURL) } catch {
            log = nil   // it runs, unrecorded
            Log.session.error("no history for session \(record.id, privacy: .public): \(error)")
        }
        var logSize = Int((try? log?.seekToEnd()) ?? 0)
        if logSize > Self.logLimit, let tail = Self.trimmed(log, logURL) { logSize = tail }
        pty = try PTY(argv: argv, cwd: record.cwd, env: env, cols: cols, rows: rows)
        rec.pid = pty.pid
        self.callbacks = callbacks
        state = OSAllocatedUnfairLock(initialState: State(record: rec, manifest: manifest, logSize: logSize, callbacks: callbacks))
        pty.onOutput = { [weak self] d in self?.handleOutput(d) }
        pty.onExit = { [weak self] code in self?.handleExit(code) }
    }

    /// Output and status start flowing.
    func start() { pty.start() }

    /// Being deleted: it stops, and neither its exit nor anything else saves its record again.
    @discardableResult
    func discard() -> [pid_t] { state.withLock { $0.discarded = true }; return pty.terminate() }
    var isDiscarded: Bool { state.withLock { $0.discarded } }
    /// The program exited and that was handled (its record final, its log closed).
    var hasEnded: Bool { state.withLock { $0.ended } }
    var topic: String? { state.withLock { $0.lastTopic } }
    /// Claude Code transcript (from hook payloads): where its subagents' transcripts live.
    var transcriptPath: String? {
        get { state.withLock { $0.transcript } }
        set { state.withLock { $0.transcript = newValue } }
    }
    var idleSeconds: TimeInterval { state.withLock { Date().timeIntervalSince($0.lastOutputAt ?? $0.started) } }
    var isAttached: Bool { state.withLock { !$0.attached.isEmpty } }
    /// The tree when its last turn started.
    var turnBase: String? { state.withLock { $0.turnTree } }
    /// Where the agent worked when its last turn started: `turnBase` is a snapshot of that folder.
    var turnDir: String? { state.withLock { $0.turnFolder } }
    var lastTurn: Turn? { state.withLock { $0.turnResult } }
    var snapshot: Session { state.withLock { $0.record } }

    /// The log's own last `ringLimit` bytes, read from the file, become the log: after a wake the ring holds only what was
    /// printed since, and trimming to that would drop most of what the session showed before its pause. Its new size.
    private static func trimmed(_ log: FileHandle?, _ url: URL) -> Int? {
        guard let log, let tail = Daemon.tail(of: url, bytes: ringLimit) else { return nil }
        try? log.truncate(atOffset: 0); try? log.write(contentsOf: tail)
        return tail.count
    }

    /// What a chunk of output asked for, done after the lock.
    private struct Heard: Sendable {
        var probe = false, topic: String?, url: String?, limits: [ClaudeLimits.Reading] = []
        var answer: (input: String, asked: NSRegularExpression)?
        var attached = Set<Int>(), id = ""
    }

    private func handleOutput(_ d: Data) {
        let text = String(decoding: d, as: UTF8.self)
        let heard = state.withLock { s -> Heard in
            s.ring.append(d)
            // A copy, at twice the limit: removeFirst on Data only re-slices, and the storage kept every byte the session
            // ever printed (300 MB of output held 300 MB). The slack makes the copy rare.
            if s.ring.count > 2 * Self.ringLimit { s.ringModes.read(s.ring.dropLast(Self.ringLimit)); s.ring = Data(s.ring.suffix(Self.ringLimit)) }
            try? log?.write(contentsOf: d); s.logSize += d.count
            if s.logSize > Self.logLimit, let n = Self.trimmed(log, logURL) { s.logSize = n }
            let said = (s.record.summary, s.record.progress)
            var h = Heard(probe: s.readReports(text, d), topic: s.readTopic(text, d))
            // The chunk without escapes, once, for the two readers that want it.
            let plain = s.interruptArmed != nil || (!s.sawURL && s.wantsURL) ? StatusDetector.stripANSI(text) : ""
            if let arm = s.interruptArmed { s.interruptArmed = (arm.at, String((arm.seen + plain).suffix(4000))) }
            if Date() > s.redrawUntil { s.detector.output(text); s.lastOutputAt = Date() }
            s.notePasteMode(d)
            h.answer = s.autoAnswer(); h.url = s.localURL(plain); h.limits = s.newLimits(d)
            h.attached = s.attached; h.id = s.record.id
            emit(s.sync() ?? (said != (s.record.summary, s.record.progress) ? s.record : nil))
            return h
        }
        if heard.probe { pty.write(Data(ProgramStatus.queryReply.utf8)) }   // "I read OSC 7501": the agent starts reporting
        if !heard.limits.isEmpty { callbacks.limits?(heard.limits) }
        if let url = heard.url { callbacks.localURL?(url) }
        if let topic = heard.topic { callbacks.topic?(topic) }
        if let answer = heard.answer { DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pressIfStillAsked(answer) } }
        callbacks.output(heard.id, d, heard.attached)
    }

    /// The auto-answer's key, once the question has had time to draw: only if it's still the one on screen and nobody
    /// typed meanwhile (the key would land in their text, or answer whatever came next).
    private func pressIfStillAsked(_ a: (input: String, asked: NSRegularExpression)) {
        let still = state.withLock { s -> Bool in
            guard !s.typedYet else { return false }
            let tail = s.screen(4000)
            return a.asked.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
        }
        if still { pty.write(Data(a.input.utf8)) }
    }

    private func handleExit(_ code: Int32) {
        state.withLock { s in
            s.ended = true
            if s.record.status == .hibernated { try? log?.close(); return }
            s.detector.exited()
            let exitCode = (code & 0x7f) == 0 ? (code >> 8) & 0xff : 0   // killed by a signal (closed, stopped) isn't a failure
            if exitCode != 0, s.record.agent != "shell" { s.record.summary = "Ended with an error (exit code \(exitCode))" }
            s.record.progress = nil; s.record.exitCode = Int((code & 0x7f) == 0 ? (code >> 8) & 0xff : 128 + (code & 0x7f))
            emit(s.sync())
            try? log?.close()
        }
    }

    /// `kelp report`: the record to publish when only what it says changed (a new state goes out through `callbacks.status`).
    func report(_ r: ProgramStatus.Report) -> Session? {
        state.withLock { s in
            s.apply(r)
            let changed = s.sync()
            emit(changed)
            return changed == nil ? s.record : nil
        }
    }

    /// Hands a change to `callbacks.status` (saved, sent to the app, turn bookkeeping) in the order the changes were made:
    /// called inside `state.withLock`, so it's queued in that order and run one after another. Called after the lock,
    /// from whichever thread made the change, an older "working" could be saved after a newer "done" and stay.
    private func emit(_ s: Session?) {
        guard let s else { return }
        statusQueue.async { self.callbacks.status(self, s) }   // holds the session until it ran: one just taken out of `live` still says so
    }
    /// `body` on the status queue, after every change queued before it.
    func inOrder(_ body: @escaping @Sendable () -> Void) { state.withLock { _ in statusQueue.async(execute: body) } }

    /// Called with every status change: a snapshot when work starts, the changes when it stops (git work off the lock).
    func noteTurn(_ status: AgentStatus) {
        let (shell, starting, ending, start, cwd) = state.withLock { s in
            // A shell or a plain command (a dev server, a script) has no turns: its output comes and goes, and each change
            // would copy the index and hash the tree again.
            let shell = s.record.agent == "shell" || s.record.agent == "custom"
            let starting = status == .working && !s.inTurn, ending = s.inTurn && status != .working
            if starting { s.inTurn = true; s.turnStart = Date(); s.turnFolder = s.record.currentDir }
            if ending { s.inTurn = false }
            return (shell, starting, ending, s.turnStart, s.turnFolder ?? s.record.cwd)
        }
        guard !shell, starting || ending else { return }
        // One after another, per session: a short turn's end waits for its own start snapshot instead of diffing against
        // the previous turn's (which credited it with that turn's changes), and snapshots can't land out of order.
        turnWork.async { [weak self] in
            if starting {
                let tree = try? Git.snapshotTree(cwd)
                self?.state.withLock { $0.turnTree = tree }
            } else if let start, let base = self?.turnBase {
                let files = ((try? Git.changesSince(tree: base, cwd: cwd)) ?? []).map { Turn.File(path: $0.path, added: $0.added, removed: $0.removed) }
                self?.state.withLock { $0.turnResult = Turn(files: files, seconds: Date().timeIntervalSince(start)) }
            }
        }
    }

    func tick() {
        steer()
        state.withLock { s in
            s.detector.tick()
            if let arm = s.interruptArmed {
                if s.lastHookAt > arm.at { s.interruptArmed = nil }
                else if Self.stoppedMarkers.contains(where: arm.seen.contains) {
                    s.detector.override(.idle); s.record.summary = "Stopped by you"; s.interruptArmed = nil
                } else if Date().timeIntervalSince(arm.at) > 10 { s.interruptArmed = nil }
            }
            emit(s.sync())
            // Deliver the launch prompt once the TUI has drawn and gone quiet (or after a timeout).
            let quiet = Date().timeIntervalSince(s.lastOutputAt ?? s.started) > 1.5   // a program that prints nothing (cat) is quiet too
            let settled = (quiet && Date().timeIntervalSince(s.started) > 2) || Date().timeIntervalSince(s.started) > 25
            if settled { s.startedUp = true }
            if let p = s.pendingPrompts.first, settled, s.readyForText() {
                s.pendingPrompts.removeFirst()
                type(p.text, enter: !p.draft, paste: p.paste, &s)   // queued here, under the lock: nothing sent meanwhile gets ahead
            }
        }
    }

    /// Keystrokes from a UI: the first submitted line becomes the source of the tab title.
    func userInput(_ d: Data) {
        pty.write(d)
        guard !TerminalReplies.isReply(d) else { return }   // the terminal answering the agent, not the user typing
        let firstPrompt = state.withLock { s -> String? in
            s.typedYet = true; s.dialogSettled = true; s.draftWaiting = false
            s.detector.input(typing: !d.contains(0x0D))   // keys without Return: the prompt is still being written
            var read: Session?
            if s.record.unread { s.record.unread = false; read = s.record }   // typing into it is having read it
            if s.hooked {
                if Self.isStopKey(d), s.record.status == .working || s.record.status == .waiting { s.interruptArmed = (Date(), "") }
                // An answer to a question or a permission menu: it works again (Claude Code sends no hook for that).
                if s.record.status == .waiting, d.contains(0x0D) || (d.count == 1 && (0x31...0x39).contains(d[0])) {
                    s.detector.override(.working); s.interruptArmed = (Date(), "")
                }
            }
            emit(s.sync() ?? read)
            return s.firstPromptLine(d)
        }
        if let line = firstPrompt { let cb = callbacks.firstPrompt; DispatchQueue.global().async { cb(line) } }
    }

    func update(_ f: @Sendable (inout Session) -> Void) -> Session { state.withLock { f(&$0.record); return $0.record } }

    /// Attached again to a program that kept running (a remote agent in its tmux session): StatusDetector.attachedToRunning.
    func attachedToRunning() { state.withLock { $0.detector.attachedToRunning() } }

    /// Hibernation: the PTY dies but the record says so, so the UI shows "Paused" instead of "Exited".
    func markHibernated() -> Session {
        state.withLock { s in s.detector.override(.hibernated); s.record.status = .hibernated; return s.record }
    }

    func overrideStatus(_ status: AgentStatus) { state.withLock { s in s.detector.override(status); emit(s.sync()) } }

    /// `trigger`: PreCompact's manual / auto; `message`: what a Notification says ("Claude needs your permission to use Bash").
    func hook(_ event: String, trigger: String? = nil, message: String? = nil) {
        state.withLock { s in
            s.lastHookAt = Date()
            let compacting = "Compacting the conversation…"
            switch event {
            case "compacting":
                s.compactManual = trigger == "manual"; s.record.summary = compacting; s.detector.hook("working")
            case "compacted":
                if s.record.summary == compacting { s.record.summary = "" }
                if s.compactManual { s.detector.override(.idle) }   // /compact finished: back at the prompt; an auto one carries on
            case "waiting":
                if let message, !message.isEmpty { s.record.summary = message }
                s.detector.hook(event)
            default: s.detector.hook(event)
            }
            emit(s.sync())
        }
    }

    /// A hook's `cwd`: where the agent works now. The record when that changed.
    func workIn(_ dir: String) -> Session? {
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path }
        let w = real(dir) == real(snapshot.cwd) ? nil : dir   // the folder it started in never changes
        return state.withLock { s in
            guard w != s.record.workDir else { return nil }
            s.record.workDir = w; return s.record
        }
    }

    /// The record when that changed it.
    func setUnread(_ unread: Bool) -> Session? {
        state.withLock { s in
            guard s.record.unread != unread else { return nil }
            s.record.unread = unread; return s.record
        }
    }

    func tail(_ n: Int) -> Data { state.withLock { $0.ring.suffix(min(max(0, n), Self.ringLimit)) } }
    /// The history, `conn` gets the output from here on. `send` runs under the lock with that history, so it goes out
    /// before any of the live output that follows. It starts by setting the modes the cut-off part had set (Codex's
    /// alternate screen and mouse reporting): without them the new terminal keeps the wheel and clicks to itself.
    @discardableResult
    func attach(_ conn: Int, send: @Sendable (Data) -> Void = { _ in }) -> Data {
        state.withLock { s in
            s.attached.insert(conn)
            var modes = s.ringModes
            modes.read(s.ring.dropLast(Self.ringLimit))
            let history = modes.restore + TerminalReplies.withoutQueries(s.ring.suffix(Self.ringLimit))
            send(history)
            return history
        }
    }
    func detach(_ conn: Int) { state.withLock { _ = $0.attached.remove(conn) } }
}

extension LiveSession {
    /// What changes, all of it: only ever read or written inside `state.withLock`. The `let`s are fixed at launch.
    struct State {
        var record: Session
        var detector: StatusDetector
        let hooked: Bool                 // agents with hooks report their state themselves; others may through OSC 7501
        let selfNames: [String]          // what a title that only names the program or its folder contains (TerminalTitle.topic)
        let started = Date()
        let wantsTopic: Bool, wantsURL: Bool, wantsLimits: Bool

        // Output: the last `ringLimit` bytes, the modes in effect where they start (what the ring dropped had set them), the log.
        var ring = Data(), ringModes = TerminalModes()
        var logSize: Int
        var attached = Set<Int>()        // connection ids receiving raw output
        var lastOutputAt: Date?
        /// TUIs redraw everything after a resize; that output isn't the agent working.
        var redrawUntil = Date.distantPast
        var discarded = false            // being deleted: nothing it does may save its record again
        var ended = false

        // What the output says.
        var oscCarry = "", titleCarry = "", lastTopic: String?
        /// The program turned on bracketed paste (ESC[?2004h): it tells a paste from typing.
        var pasteMode = false, pasteCarry = Data()
        var sawURL = false, lastLimits: [ClaudeLimits.Reading] = []
        var transcript: String?
        var lastHookAt = Date.distantPast, compactManual = false
        /// Esc / ⌃C / an answer while it works or asks: Claude Code sends no hook when a turn is cut short, so the
        /// screen decides ("Interrupted…") within a few seconds. `seen` is the text printed since.
        var interruptArmed: (at: Date, seen: String)?

        // Typing into it (LiveSessionInput).
        var autoAnswers: [(NSRegularExpression, AgentManifest.AutoAnswer)]
        /// Drawn and quiet once (or 25 s up): text typed before then could land in a program still starting.
        var startedUp = false
        /// Text waiting until the program is ready (drawn, quiet, no question open), first in first out: the launch
        /// prompt, then whatever was sent while it waited.
        var pendingPrompts: [(text: String, draft: Bool, paste: Bool)] = []
        /// Someone answered the agent's first question (the user typed, or Kelp's auto-answer pressed its key): from then
        /// on a trust dialog's words left in the scrollback no longer hold the launch prompt back.
        var dialogSettled = false
        /// A draft is typed but not sent (an issue's brief, a hand-off's): the user reads it and presses Return. Until they
        /// type anything, text sent meanwhile waits behind it — its Enter would submit the draft unread.
        var draftWaiting = false
        /// Anything typed into it yet, by the user or by Kelp (a prompt): startup answers are only for what the agent asks
        /// before that. After it, a matching line is something the agent read or wrote, not its own dialog.
        var typedYet = false
        /// Menu answer in progress: move one step at a time, re-reading the screen, and press Enter only on the wanted
        /// option. `screen`: what must still be on screen for each key (the dialog being answered); nil for a menu the
        /// user answers from a notification.
        var steering: (choose: NSRegularExpression, since: Date, lastKey: Date, screen: NSRegularExpression?)?
        var inputLine = "", sawFirstPrompt = false

        // Turns: written by turnWork, read by requests.
        var turnTree: String?, turnFolder: String?, turnResult: Turn?, turnStart: Date?, inTurn = false

        init(record: Session, manifest: AgentManifest, logSize: Int, callbacks: Callbacks) {
            self.record = record
            detector = StatusDetector(manifest: manifest)
            hooked = manifest.hooksSettingsFlag != nil
            selfNames = [manifest.id, manifest.name, (record.cwd as NSString).lastPathComponent]
            autoAnswers = manifest.autoAnswers.compactMap { a in (try? NSRegularExpression(pattern: a.pattern)).map { ($0, a) } }
            self.logSize = logSize
            wantsTopic = callbacks.topic != nil; wantsURL = callbacks.localURL != nil; wantsLimits = callbacks.limits != nil
        }

        /// The last `bytes` of what it printed, without escapes: what's on screen, near enough.
        func screen(_ bytes: Int) -> String { StatusDetector.stripANSI(String(decoding: ring.suffix(bytes), as: UTF8.self)) }

        // What a chunk of output says. Whether a chunk has a sequence at all is asked of its bytes: String.contains
        // compares Characters, and on a stream of output that was most of the daemon's time.

        /// OSC 7501 reports (true: the agent asked whether Kelp reads them) and ConEmu progress.
        mutating func readReports(_ text: String, _ d: Data) -> Bool {
            var probe = false
            if !hooked, d.range(of: Data(ProgramStatus.prefix.utf8)) != nil || !oscCarry.isEmpty {
                for m in ProgramStatus.scan(text, carry: &oscCarry) {
                    switch m {
                    case .query: probe = true
                    case .report(let r) where r.id == nil: apply(r)   // children (subagents) aren't shown
                    default: break
                    }
                }
            }
            if d.range(of: Data(ProgramStatus.conEmuPrefix.utf8)) != nil, let p = ProgramStatus.conEmuProgress(text).last { record.progress = p }
            return probe
        }

        /// A new topic from the terminal title the agent sets.
        mutating func readTopic(_ text: String, _ d: Data) -> String? {
            guard wantsTopic, d.range(of: Data("\u{1B}]".utf8)) != nil || !titleCarry.isEmpty,
                  let t = TerminalTitle.scan(text, carry: &titleCarry).last.flatMap({ TerminalTitle.topic($0, names: selfNames) }), t != lastTopic else {
                return nil
            }
            lastTopic = t
            return t
        }

        /// Bracketed paste switched on or off (the sequence can be split across two reads).
        mutating func notePasteMode(_ d: Data) {
            let scan = pasteCarry + d
            if let on = scan.range(of: Data("\u{1B}[?2004".utf8), options: .backwards), on.upperBound < scan.endIndex { pasteMode = scan[on.upperBound] == UInt8(ascii: "h") }
            pasteCarry = Data(d.suffix(7))
        }

        /// The keys that answer a question the manifest knows (a menu is steered instead, see `steer`).
        mutating func autoAnswer() -> (input: String, asked: NSRegularExpression)? {
            guard !autoAnswers.isEmpty, !typedYet, Date().timeIntervalSince(started) < 90 else { return nil }
            let tail = screen(4000)
            let r = NSRange(tail.startIndex..., in: tail)
            guard let i = autoAnswers.firstIndex(where: { $0.0.firstMatch(in: tail, range: r) != nil }) else { return nil }
            let a = autoAnswers[i].1
            if let choose = a.choose, let re = try? NSRegularExpression(pattern: choose) {
                steering = (re, Date(), .distantPast, autoAnswers[i].0); autoAnswers.remove(at: i)   // closed loop, see steer()
                return nil
            }
            let asked = autoAnswers.remove(at: i).0; dialogSettled = true
            return (a.input, asked)
        }

        /// The first local URL it prints (a dev server), with 0.0.0.0 and [::] as localhost.
        mutating func localURL(_ plain: String) -> String? {
            guard !sawURL, wantsURL, let m = LiveSession.urlRegex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
                  let r = Range(m.range, in: plain) else { return nil }
            sawURL = true
            return String(plain[r]).replacingOccurrences(of: "0.0.0.0", with: "localhost").replacingOccurrences(of: "[::]", with: "localhost")
        }

        /// Plan limits Claude Code printed, when they changed.
        mutating func newLimits(_ d: Data) -> [ClaudeLimits.Reading] {
            guard wantsLimits, d.range(of: Data("limit".utf8)) != nil else { return [] }
            let found = ClaudeLimits.parse(screen(1200))
            guard !found.isEmpty, found != lastLimits else { return [] }
            lastLimits = found
            return found
        }

        /// What the program says about itself (OSC 7501 or `kelp report`): its state, a message for its row, how far it got.
        mutating func apply(_ r: ProgramStatus.Report) {
            detector.program(r.state); lastHookAt = Date()
            if let msg = r.msg, !msg.isEmpty { record.summary = msg } else if r.state == "idle" || r.state == "clear" { record.summary = "" }
            record.progress = r.progress
        }

        /// The detector's status into the record; the record when it changed. Ended is final: a hook or a keystroke that
        /// arrives after the exit doesn't bring the session back.
        mutating func sync() -> Session? {
            let s = detector.status
            guard s != record.status, record.status != .exited else { return nil }
            record.status = s
            if s == .done || s == .waiting || s == .exited || s == .error { record.unread = true }
            return record
        }

        /// Keys typed until the first line of 8 characters or more is submitted: that line (once), which names the session.
        mutating func firstPromptLine(_ d: Data) -> String? {
            guard !sawFirstPrompt else { return nil }
            var s = String(decoding: d, as: UTF8.self)
            if s.hasPrefix("\u{1B}[200~") { s = s.replacingOccurrences(of: "\u{1B}[200~", with: "").replacingOccurrences(of: "\u{1B}[201~", with: "") }
            else if s.hasPrefix("\u{1B}") { return nil }   // arrows, function keys
            for ch in s {
                switch ch {
                case "\r", "\n":
                    let line = inputLine.trimmingCharacters(in: .whitespaces); inputLine = ""
                    if line.count >= 8 { sawFirstPrompt = true; return line }
                case "\u{7F}", "\u{08}": if !inputLine.isEmpty { inputLine.removeLast() }
                default: if !ch.isASCII || ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol || ch == " " { inputLine.append(ch) }
                }
            }
            return nil
        }
    }
}
