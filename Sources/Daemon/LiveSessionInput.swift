import Foundation
import Core
import Agents

/// Typing into a session: what holds text back (a trust question, a startup menu, text queued before it), answering an
/// agent's menu, and sending text as text.
extension LiveSession {
    /// Caller holds the lock.
    func trustQuestionOpen() -> Bool {
        guard !dialogSettled else { return false }
        let tail = StatusDetector.stripANSI(String(decoding: ring.suffix(4000), as: UTF8.self))
        return Self.trustQuestion?.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
    }
    private static let trustQuestion = try? NSRegularExpression(pattern: AgentManifest.trust.pattern)

    /// A numbered menu with its cursor on screen ("❯ 1. Use this and all future MCP servers"). The input box's own "❯"
    /// is followed by text, not "1.", and once a menu is answered the newer cursor is the input box's. Caller holds the lock.
    func menuOpen() -> Bool {
        let screen = StatusDetector.stripANSI(String(decoding: ring.suffix(1500), as: UTF8.self))
        guard let option = AgentManifest.AutoAnswer.optionAtCursor(screen) else { return false }
        return option.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }

    /// Called on every tick. Reads the latest menu render; Enter only when the cursor sits on the wanted option.
    func steer() {
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

    func queuePrompt(_ p: String, draft: Bool = false) { lock.lock(); pendingPrompts.append((p, draft)); sawFirstPrompt = true; lock.unlock() }
    /// Text still waiting for the program: anything sent now goes behind it.
    var hasPendingInput: Bool { lock.withLock { !pendingPrompts.isEmpty } }

    /// Type text into the agent. Multi-line text goes as a bracketed paste so TUIs don't submit each line.
    /// `paste`: as a paste even on one line (when the program takes pastes), so a leading "!" or "/" (an issue title) is
    /// text, not a mode or command.
    /// Without it one line is typed, so `kelp send <id> /compact` still runs the command.
    func send(_ text: String, enter: Bool, paste: Bool = false) {
        let takesPastes = lock.withLock { detector.input(); typedYet = true; return pasteMode }
        var text = Self.typeable(text)
        // Not to be sent (a draft: an issue's text, say) to a program that takes no pastes: each newline would submit a
        // line of it. One line instead, so nothing goes before the user presses Return.
        if !enter, !takesPastes { text = text.replacingOccurrences(of: "\n", with: " ") }
        // A program that never asked for pastes (a plain line reader) has no modes to trip: it gets the text as is.
        let body = (paste || text.contains("\n")) && takesPastes ? "\u{1B}[200~" + text + "\u{1B}[201~" : text
        // One after another, Enter included: two quick sends must arrive as text, Enter, text, Enter, not text, text, Enter, Enter.
        sends.async { [weak self] in
            self?.pty.write(Data(body.utf8))
            if enter { Thread.sleep(forTimeInterval: 0.3); self?.pty.write(Data("\r".utf8)) }
        }
    }

    /// Text from elsewhere (an issue, a recipe, a review comment) as plain text: no escape sequences and no control keys but
    /// newlines and tabs. An issue body with ESC[201~ would end the paste, then Return, Shift-Tab or "!cmd" would act as keys.
    static func typeable(_ s: String) -> String {
        String(String.UnicodeScalarView(s.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter { c in
            c == "\n" || c == "\t" || !(c.value < 0x20 || c.value == 0x7F || (0x80...0x9F).contains(c.value))
        }))
    }
}
