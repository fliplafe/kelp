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
        if LocalAI.isAvailable, let c = AppModel.shared.client,
           let tail = (try? await c.call("session.read", .obj(["id": .string(s.id), "bytes": 3000])))?.string,
           let st = await LocalAI.agentState(tail: StatusDetector.withoutPromptHints(tail)) {
            s.summary = st.summary
            var p: [String: JSONValue] = ["id": .string(s.id), "summary": .string(st.summary)]
            if st.waitingForUser, s.status == .done { p["status"] = "waiting"; s.status = .waiting }
            _ = try? await AppModel.shared.client?.call("session.annotate", .object(p))
        }
        post(s)
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
