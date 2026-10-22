import AppKit
import Core
import WorkbenchKit

/// An agent or terminal session as a tab (libghostty via PaneView; the daemon keeps the process).
@MainActor
final class SessionTab: TabContent {
    let sessionId: String
    let pane: PaneView
    var onChange: (() -> Void)?
    var uri: String { TabURI.session(sessionId) }
    var view: NSView { pane }

    init?(uri: String) {
        let sid = TabURI.body(uri)
        guard let s = AppModel.shared.session(sid) else { return nil }
        sessionId = sid
        pane = PaneView(session: s)
        pane.onRestart = { p in AgentActions.restart(p.sessionId) }
        pane.onClose = { p in Workbench.closeTab(uri: TabURI.session(p.sessionId)) }
        track(owner: self) { AppModel.shared.session(sid) } changed: { [weak self] s in
            guard let self, let s else { return }
            pane.update(s); onChange?()
        }
    }

    private var session: Session? { AppModel.shared.session(sessionId) }
    var title: String {
        session.map(AgentCatalog.displayName) ?? String(localized: "Session")
    }
    var icon: NSImage? { AgentCatalog.icon(session?.agent) }
    /// A terminal shows a state only while a program in it says how far it got (a build).
    var status: AgentStatus? { session.flatMap { $0.agent == "shell" ? ($0.progress == nil ? nil : .working) : $0.endedWithError ? .error : $0.markStatus } }
    var progress: Double? { session?.progress.map { Double($0) / 100 } }
    /// The ring around its pane: it asks (orange), failed (red), or finished and wasn't looked at yet (accent).
    var attention: NSColor? {
        guard let s = session, s.agent != "shell" else { return nil }
        if s.status == .waiting { return .systemOrange }
        if s.status == .error || s.endedWithError { return s.unread ? .systemRed : nil }
        return s.status == .done && s.unread ? .controlAccentColor : nil
    }
    var unread: Bool { session?.unread ?? false }
    var isTerminal: Bool { true }
    /// Only one on screen: a hidden pane's grid is from whatever size it last had.
    var terminalGrid: (cols: Int, rows: Int)? { pane.window == nil ? nil : pane.gridSize }
    var meter: Double? { AppModel.shared.contextShare[sessionId] }
    var toolTip: String? {
        session.map { "\(title) — \($0.statusWords)" + ($0.summary.isEmpty ? "" : "\n\($0.summary)") + ($0.workingElsewhere.map { "\n\($0)" } ?? "") }
    }
    func focus() { pane.focus() }

    /// Closing the tab ends the session; it asks only when something would stop: a working agent, or a program
    /// running in a terminal (an idle shell or a finished agent just closes).
    func close() async -> Bool { await Self.close(session: sessionId) }

    /// Its items in the tab's context menu.
    static func menu(_ m: NSMenu, uri: String, workspace: String, openBeside: @escaping @MainActor (String) -> Void) {
        let sid = TabURI.body(uri)
        m.add(String(localized: "Rename…")) { AgentActions.rename(sid) }
        m.add(String(localized: "Restart")) { AgentActions.restart(sid) }
        m.add(String(localized: "Copy Context")) { AgentActions.copyContext(sid) }
        m.setSubmenu(AgentActions.handoffMenu(sid), for: m.addItem(withTitle: String(localized: "Hand Off to"), action: nil, keyEquivalent: ""))
        m.add(String(localized: "Changes in Its Last Turn")) {
            Workbench.shared.focusedSession = sid
            openBeside(TabURI.diff(workspace, source: "turn"))
        }
    }

    /// Also for a tab that was never built (EditorArea closes those without making them).
    static func close(session sid: String) async -> Bool {
        let session = AppModel.shared.session(sid)
        if let s = session, s.agent != "shell", s.status == .working {
            let a = NSAlert(); a.messageText = String(localized: "Stop \(AgentCatalog.displayName(s))?")
            a.informativeText = String(localized: "The agent is still working. Closing the tab ends its session.")
            a.addButton(withTitle: String(localized: "Stop Agent")); a.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(a) == .alertFirstButtonReturn else { return false }
        } else if session?.agent == "shell", let program = await busy(sid) {
            let a = NSAlert()
            a.messageText = String(localized: "Stop “\(program)”?"); a.informativeText = String(localized: "It is still running in this terminal. Closing the tab stops it.")
            a.addButton(withTitle: String(localized: "Stop and Close")); a.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(a) == .alertFirstButtonReturn else { return false }
        }
        Task { await AppModel.shared.call(SessionKill(id: sid)) }
        return true
    }

    /// What runs in the foreground of a terminal: the tab closes or stays on this answer. A daemon that doesn't answer
    /// within 2 s closes the tab as if nothing ran.
    private static func busy(_ sid: String) async -> String? {
        await AppModel.shared.quiet(SessionBusy(id: sid), timeout: 2) ?? nil
    }
}
