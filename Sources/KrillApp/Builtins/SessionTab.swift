import AppKit
import Core

/// An agent or terminal session as a tab (libghostty via PaneView; the daemon keeps the process).
@MainActor
final class SessionTab: TabContent {
    let sessionId: String
    let pane: PaneView
    var onChange: (() -> Void)?
    private var observer: NSObjectProtocol?
    var uri: String { TabURI.session(sessionId) }
    var view: NSView { pane }

    init?(uri: String) {
        let sid = TabURI.body(uri)
        guard let s = AppModel.shared.session(sid) else { return nil }
        sessionId = sid
        pane = PaneView(session: s)
        pane.onRestart = { p in AgentActions.restart(p.sessionId) }
        pane.onClose = { p in Workbench.closeTab(uri: TabURI.session(p.sessionId)) }
        observer = NotificationCenter.default.addObserver(forName: .krillSession, object: sid, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = AppModel.shared.session(self.sessionId) else { return }
                self.pane.update(s); self.onChange?()
            }
        }
    }
    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private var session: Session? { AppModel.shared.session(sessionId) }
    var title: String {
        guard let s = session else { return "Session" }
        if !s.title.isEmpty { return s.title }
        return s.agent == "shell" ? "Terminal" : AgentCatalog.name(s.agent)
    }
    var icon: NSImage? { AgentCatalog.icon(session?.agent) }
    var status: AgentStatus? { session.flatMap { $0.agent == "shell" ? nil : $0.status } }
    var toolTip: String? { session.map { "\(title) — \($0.status.words)" + ($0.summary.isEmpty ? "" : "\n\($0.summary)") } }
    func focus() { pane.focus() }

    /// Closing the tab ends the session; a working agent asks first.
    func close() -> Bool {
        if let s = session, s.agent != "shell", s.status == .working {
            let a = NSAlert(); a.messageText = "Stop \(title)?"; a.informativeText = "The agent is still working. Closing the tab ends its session."
            a.addButton(withTitle: "Stop Agent"); a.addButton(withTitle: "Cancel")
            guard runAsSheet(a) == .alertFirstButtonReturn else { return false }
        }
        Task { await AppModel.shared.call("session.kill", .obj(["id": .string(sessionId)])) }
        return true
    }
}

extension Notification.Name { static let krillSession = Notification.Name("krill.session") }
