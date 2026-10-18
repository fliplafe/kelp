import AppKit
import Core

/// ⌃`: a floating shell above every window, not tied to a worktree. The session survives toggling.
@MainActor
final class FloatingTerminal {
    static let shared = FloatingTerminal()
    private var panel: NSPanel?

    func toggle() {
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        Task { await show() }
    }

    /// Show a specific session (e.g. a resumed conversation outside any worktree) in the floating panel.
    func show(session s: Session) {
        UserDefaults.standard.set(s.id, forKey: "floatingSession"); panel = nil
        Task { await show() }
    }

    private func show() async {
        let saved = UserDefaults.standard.string(forKey: "floatingSession")
        var session = saved.flatMap { AppModel.shared.session($0) }.flatMap { $0.status == .exited ? nil : $0 }
        if session == nil {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard let r = await AppModel.shared.call("session.create", .obj(["cwd": .string(home), "agent": "shell", "title": "Floating terminal"])),
                  let s = try? r.decode(Session.self) else { return }
            AppModel.shared.sessions.append(s); session = s
            UserDefaults.standard.set(s.id, forKey: "floatingSession")
        }
        guard let s = session else { return }
        if panel == nil || (panel?.contentView as? PaneView)?.sessionId != s.id {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = "Terminal"; p.isFloatingPanel = true; p.level = .floating; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.setFrameAutosaveName("floatingTerminal"); p.isReleasedWhenClosed = false
            let pane = PaneView(session: s)
            pane.onClose = { [weak p] _ in p?.orderOut(nil) }
            p.contentView = pane
            if p.frame.origin == .zero { p.center() }
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
        (panel?.contentView as? PaneView)?.focus()
    }
}
