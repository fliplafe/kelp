import AppKit
import Core
import WorkbenchKit

/// Present an alert as a sheet on the main window and await the answer (native, non-blocking).
@MainActor
func runSheet(_ a: NSAlert) async -> NSApplication.ModalResponse {
    guard let w = NSApp.keyWindow ?? NSApp.mainWindow else { return a.runModal() }
    return await withCheckedContinuation { c in a.beginSheetModal(for: w) { c.resume(returning: $0) } }
}

/// The window a synchronous sheet goes on: key / main are nil while Kelp isn't the active app, the sheet still belongs
/// on its window; one that already shows a sheet can't take another.
@MainActor
private func sheetWindow() -> NSWindow? {
    guard let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), w.attachedSheet == nil else { return nil }
    return w
}

/// An alert as a sheet on the front window, answered synchronously (for code that needs the answer right away).
@MainActor
func runAsSheet(_ a: NSAlert) -> NSApplication.ModalResponse {
    guard let w = sheetWindow() else { return a.runModal() }
    a.beginSheetModal(for: w) { NSApp.stopModal(withCode: $0) }
    return NSApp.runModal(for: a.window)
}

/// A save panel as a sheet on the front window, answered synchronously (closing a tab or quitting needs the answer).
@MainActor
func runAsSheet(_ p: NSSavePanel) -> NSApplication.ModalResponse {
    guard let w = sheetWindow() else { return p.runModal() }
    p.beginSheetModal(for: w) { NSApp.stopModal(withCode: $0) }
    return NSApp.runModal(for: p)
}

/// Session-level agent actions shared by tabs and the sidebar.
@MainActor
enum AgentActions {
    static func rename(_ sid: String) {
        let cur = AppModel.shared.session(sid)?.title ?? ""
        guard let t = prompt(String(localized: "Rename"), String(localized: "Leave empty to name it from the task automatically."), initial: cur) else { return }
        Task { await AppModel.shared.call(SessionRename(id: sid, title: t)) }
    }

    /// Same command in the same tab; resumes the conversation when the agent supports it.
    static func restart(_ sid: String) {
        Task {
            guard let r = await AppModel.shared.call("session.restart", .obj(["id": .string(sid)])), let s = try? r.decode(Session.self) else { return }
            AppModel.shared.sessions.removeAll { $0.id == sid }
            AppModel.shared.upsert(s)
            Workbench.editor?.replace(session: sid, with: s.id)
        }
    }

    static func stop(_ ids: [String]) {
        let one = ids.count == 1
        let a = NSAlert(); a.messageText = one ? String(localized: "Stop this agent?") : String(localized: "Stop \(ids.count) agents?")
        a.informativeText = (one ? String(localized: "Its session ends") : String(localized: "Their sessions end")) + ". " + String(localized: "Conversations can be resumed from Session History.")
        // The button says what it stops (destructive: red).
        a.addButton(withTitle: one ? String(localized: "Stop Agent") : String(localized: "Stop \(ids.count) Agents")).hasDestructiveAction = true; a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            for id in ids { await AppModel.shared.call("session.kill", .obj(["id": .string(id)])) }
        }
    }

    /// "Hand Off to ▸ Codex": a new agent in the same workspace gets what this one did (its conversation, or the
    /// terminal's text) as a brief typed into its prompt, not sent. ⌥ hands over the full transcript instead of the latest part.
    static func handoffMenu(_ sid: String) -> NSMenu {
        let m = NSMenu()
        for a in AgentCatalog.installed(AgentCatalog.all) {
            m.add(a.name) { handoff(sid, to: a.id, full: false) }.image = AgentCatalog.icon(a.id)
            let full = m.add(String(localized: "\(a.name) — Full Transcript")) { handoff(sid, to: a.id, full: true) }
            full.isAlternate = true; full.keyEquivalentModifierMask = .option; full.image = AgentCatalog.icon(a.id)
        }
        return m
    }

    static func handoff(_ sid: String, to agent: String, full: Bool) {
        Task {
            let p: JSONValue = .obj(["id": .string(sid), "agent": .string(agent), "full": .bool(full), "draft": true,
                                     "prompt": "Continue the task where the previous agent left off: check what's done, then finish it."])
            guard let r = await AppModel.shared.call("session.handoff", p), let s = try? r.decode(Session.self) else { return }
            AppModel.shared.upsert(s)
            Workbench.open(TabURI.session(s.id), split: .right, workspace: s.worktreeId)
        }
    }

    static func copyContext(_ sid: String) {
        Task {
            guard let t = await AppModel.shared.call("session.context", .obj(["id": .string(sid)]))?.string else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
            Banner.show(String(localized: "Context copied"))
        }
    }
}

/// A one-field question (rename, go to line…).
@MainActor
func prompt(_ title: String, _ info: String, initial: String = "") -> String? {
    let a = NSAlert(); a.messageText = title; a.informativeText = info
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); f.stringValue = initial
    a.accessoryView = f; a.addButton(withTitle: String(localized: "OK")); a.addButton(withTitle: String(localized: "Cancel"))
    a.window.initialFirstResponder = f
    return runAsSheet(a) == .alertFirstButtonReturn ? f.stringValue : nil
}
