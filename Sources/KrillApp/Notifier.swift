import AppKit
import UserNotifications
import Core
import LocalAI
import Agents

/// Banner + dock badge when an agent finishes or waits; clicking opens the right pane.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier != nil ? .current() : nil   // needs an app bundle

    func start() {
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        AppModel.shared.onSessionStatus.append { [weak self] new, old in self?.statusChanged(new, old) }
        AppModel.shared.onChange.append { [weak self] in self?.updateBadge() }
    }

    func updateBadge() {
        let n = AppModel.shared.sessions.filter { $0.unread && $0.status != .exited }.count
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    private func statusChanged(_ s: Session, _ old: Session?) {
        guard old?.status != s.status, s.status == .done || s.status == .waiting, s.agent != "shell" else { return }
        Task { await summarizeThenNotify(s) }
    }

    /// The local model reads the terminal tail: one-line summary for the banner and sidebar, and a second
    /// opinion on "needs you" vs "done" for agents without hooks.
    private func summarizeThenNotify(_ s: Session) async {
        var s = s
        // Claude Code: its own last reply (the terminal around it — spinners, mode lines — reads as nonsense when summarized).
        // The Stop hook can come a moment before the transcript has the final message.
        try? await Task.sleep(for: .milliseconds(1200))
        if let c = AppModel.shared.client, let reply = (try? await c.call("session.lastReply", .obj(["id": .string(s.id)])))?.string {
            let line = Self.firstSentence(reply)   // its own words beat the small on-device model's paraphrase
            s.summary = line
            _ = try? await c.call("session.annotate", .obj(["id": .string(s.id), "summary": .string(line)]))
            post(s); return
        }
        if LocalAI.isAvailable, let c = AppModel.shared.client,
           let tail = (try? await c.call("session.read", .obj(["id": .string(s.id), "bytes": 3000])))?.string,
           let st = await LocalAI.agentState(tail: Self.withoutChrome(StatusDetector.withoutPromptHints(tail))) {
            s.summary = st.summary
            var p: [String: JSONValue] = ["id": .string(s.id), "summary": .string(st.summary)]
            // Agents with hooks report real questions themselves; a closing "let me know if…" isn't one.
            let hooked = AgentCatalog.all.first { $0.id == s.agent }?.hooksSettingsFlag != nil
            if st.waitingForUser, s.status == .done, !hooked { p["status"] = "waiting"; s.status = .waiting }
            _ = try? await AppModel.shared.client?.call("session.annotate", .object(p))
        }
        post(s)
    }

    /// "I added `mul(a, b)` to `calc.py`. It returns…" → "Added mul(a, b) to calc.py".
    static func firstSentence(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "`", with: "").split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let end = line.firstIndex { ".!?".contains($0) }.map { line.index(after: $0) } ?? line.endIndex
        var s = String(line[..<end]).trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(".") { s.removeLast() }
        for lead in ["I've ", "I have ", "I "] where s.hasPrefix(lead) {
            s = String(s.dropFirst(lead.count)); s = s.prefix(1).uppercased() + s.dropFirst(); break
        }
        return s.count > 90 ? String(s.prefix(89)) + "…" : s
    }

    /// Terminal lines that are the agent UI's chrome, not its words: borders, mode / hint bars, spinner and timing lines.
    static func withoutChrome(_ tail: String) -> String {
        tail.split(separator: "\n", omittingEmptySubsequences: false).filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return true }
            if t.unicodeScalars.allSatisfy({ (0x2500...0x257F).contains($0.value) || $0 == " " }) { return false }   // box drawing
            let lower = t.lowercased()
            return !["shift+tab", "auto mode", "esc to interrupt", "ctrl+", "tokens", "· done", "for help", "bypass permissions"].contains { lower.contains($0) }
                && t.range(of: #"^[^\w\s]\s*\w+…"#, options: .regularExpression) == nil   // "✻ Ebbing…" spinners
        }.joined(separator: "\n")
    }

    private func post(_ s: Session) {
        // No banner if the user is already looking at that pane.
        if NSApp.isActive, (NSApp.delegate as? AppDelegate)?.isViewing(session: s.id) == true { Task { await AppModel.shared.call("session.markRead", .obj(["id": .string(s.id)])) }; return }
        let wt = AppModel.shared.worktree(s.worktreeId)
        let c = UNMutableNotificationContent()
        c.title = s.status == .waiting ? "\(s.agent ?? "Agent") needs you" : "\(s.agent ?? "Agent") finished"
        c.title = s.status == .waiting ? "\(s.displayTitle) needs you" : "\(s.displayTitle) finished"
        c.subtitle = wt?.branch ?? ""
        c.body = s.summary.isEmpty ? (s.status == .waiting ? "Waiting for your answer" : "Ready for review") : s.summary
        c.sound = .default; c.userInfo = ["session": s.id]
        center?.add(UNNotificationRequest(identifier: "\(s.id)-\(s.status.rawValue)", content: c, trigger: nil))
        NSApp.requestUserAttention(.informationalRequest)
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        guard let id = r.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run { NSApp.activate(); self.onOpen?(id) }
    }
    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
