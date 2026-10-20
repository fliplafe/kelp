import AppKit
import UserNotifications
import Core

/// Banner + dock badge when an agent finishes or waits; clicking opens the right pane.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    /// macOS lets Kelp show banners (false: they're off in System Settings).
    private var allowed = true
    private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier != nil ? .current() : nil   // needs an app bundle

    func start() {
        center?.delegate = self
        // A permission request can be answered from the banner itself.
        center?.setNotificationCategories([UNNotificationCategory(identifier: "permission", actions: [
            UNNotificationAction(identifier: "allow", title: String(localized: "Allow")),
            UNNotificationAction(identifier: "deny", title: String(localized: "Deny"), options: [.destructive])
        ], intentIdentifiers: [])])
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in Task { @MainActor in self.checkAllowed() } }
        track { AppModel.shared.sessions } changed: { [weak self] _ in self?.updateBadge() }
    }

    /// macOS can switch Kelp's banners off (System Settings › Notifications): say so once, instead of failing silently.
    /// Called at launch and when Kelp comes to the front.
    func checkAllowed() {
        center?.getNotificationSettings { s in
            let off = s.authorizationStatus == .denied || s.alertSetting == .disabled
            Task { @MainActor in
                self.allowed = !off
                let d = UserDefaults.standard
                guard off else { d.removeObject(forKey: "notifications.warnedOff"); return }
                guard !d.bool(forKey: "notifications.warnedOff") else { return }
                d.set(true, forKey: "notifications.warnedOff")
                Banner.show(String(localized: "Notifications for Kelp are turned off in System Settings, so you won't hear when an agent needs you."), style: .error,
                            action: (String(localized: "Open Settings"), {
                                let id = Bundle.main.bundleIdentifier ?? ""
                                if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") { NSWorkspace.shared.open(u) }
                            }))
            }
        }
    }

    /// First launch's "Send Test Notification": a banner now, or `false` when macOS has them turned off for Kelp.
    func sendTest(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let center else { done(false); return }
        center.getNotificationSettings { s in
            let off = s.authorizationStatus == .denied || s.alertSetting == .disabled
            Task { @MainActor in
                if !off {
                    let c = UNMutableNotificationContent()
                    c.title = String(localized: "Kelp can reach you"); c.body = String(localized: "This is how you'll hear that an agent finished or needs you."); c.sound = .default
                    try? await center.add(UNNotificationRequest(identifier: "kelp-test", content: c, trigger: nil))
                }
                done(!off)
            }
        }
    }

    func updateBadge() {
        let n = AppModel.shared.sessions.filter { $0.unread && $0.status != .exited }.count
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
        clearSeen()
    }

    /// Banners already answered (the agent was looked at, or moved on) leave Notification Center, like Messages does.
    private var posted: [String: String] = [:]   // session → request id
    private func clearSeen() {
        let stale = posted.filter { sid, rid in
            guard let s = AppModel.shared.session(sid) else { return true }
            return !s.unread || !rid.hasSuffix(s.status.rawValue)
        }
        guard !stale.isEmpty else { return }
        center?.removeDeliveredNotifications(withIdentifiers: Array(stale.values))
        stale.keys.forEach { posted[$0] = nil }
    }

    /// Each `event.session`, as it comes: a status that changes back within a moment still gets its banner.
    func statusChanged(_ s: Session, _ old: Session?) {
        guard old?.status != s.status, [.done, .waiting, .error].contains(s.status), s.agent != "shell" else { return }
        // What the agent itself said with this change (a permission request, an error) beats its last reply.
        if s.status != .done, !s.summary.isEmpty, s.summary != old?.summary { post(s); return }
        Task { await summarizeThenNotify(s) }
    }

    /// One-line summary for the banner and sidebar from the agent's own last reply, then the notification.
    private func summarizeThenNotify(_ s: Session) async {
        var s = s
        // Claude Code: its own last reply (the terminal around it — spinners, mode lines — reads as nonsense when summarized).
        // The Stop hook can come a moment before the transcript has the final message.
        try? await Task.sleep(for: .milliseconds(1200))
        if let c = AppModel.shared.client, let reply = (try? await c.call("session.lastReply", .obj(["id": .string(s.id)])))?.string {
            let line = Self.firstSentence(reply)
            s.summary = line
            _ = try? await c.call("session.annotate", .obj(["id": .string(s.id), "summary": .string(line)]))
            post(s); return
        }
        // Other agents: no summary; the state says enough.
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

    private func post(_ s: Session) {
        // No banner if the user is already looking at that pane.
        // No banner if the user is already looking at that pane (what it asks stays marked until it's answered).
        if NSApp.isActive, (NSApp.delegate as? AppDelegate)?.isViewing(session: s.id) == true { return }
        let wt = AppModel.shared.worktree(s.worktreeId)
        let c = UNMutableNotificationContent()
        c.title = AgentCatalog.displayName(s) + (s.status == .waiting ? String(localized: " needs you") : s.status == .error ? String(localized: " ran into an error") : " finished")
        c.subtitle = wt?.branch ?? ""
        c.body = s.summary.isEmpty ? (s.status == .waiting ? String(localized: "Waiting for your answer") : String(localized: "Ready for review")) : s.summary
        c.sound = .default; c.userInfo = ["session": s.id]
        if Self.asksPermission(s) { c.categoryIdentifier = "permission" }
        if !allowed, NSApp.isActive {   // banners are off: say it inside Kelp instead
            Banner.show("\(c.title)\(s.summary.isEmpty ? "" : ": " + s.summary)", action: (String(localized: "Show"), { Workbench.focus(session: s.id) }))
        }
        let rid = "\(s.id)-\(s.status.rawValue)"
        center?.add(UNNotificationRequest(identifier: rid, content: c, trigger: nil))
        posted[s.id] = rid
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// "Claude needs your permission to use Bash", a blocked OSC report of kind permission…
    static func asksPermission(_ s: Session) -> Bool {
        let t = s.summary.lowercased()
        return s.status == .waiting && ["permission", "approve", "allow"].contains { t.contains($0) }
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        guard let id = r.notification.request.content.userInfo["session"] as? String else { return }
        let action = r.actionIdentifier
        await MainActor.run {
            guard action == "allow" || action == "deny" else { NSApp.activate(); self.onOpen?(id); return }
            Task {
                // Answered without Kelp coming forward; if the menu is gone (answered in the terminal), show the agent.
                let ok = await AppModel.shared.call("session.choose", .obj(["id": .string(id), "answer": .string(action)]))?.bool ?? false
                if !ok { NSApp.activate(); self.onOpen?(id) }
            }
        }
    }
    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
