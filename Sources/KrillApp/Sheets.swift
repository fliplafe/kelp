import AppKit
import Core
import Agents

/// Present an alert as a sheet on the main window and await the answer (native, non-blocking).
@MainActor
func runSheet(_ a: NSAlert) async -> NSApplication.ModalResponse {
    guard let w = NSApp.keyWindow ?? NSApp.mainWindow else { return a.runModal() }
    return await withCheckedContinuation { c in a.beginSheetModal(for: w) { c.resume(returning: $0) } }
}

/// An alert as a sheet on the front window, answered synchronously (for code that needs the answer right away).
@MainActor
func runAsSheet(_ a: NSAlert) -> NSApplication.ModalResponse {
    // Key / main are nil while Krill isn't the active app; the sheet still belongs on its window.
    guard let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
          w.attachedSheet == nil else { return a.runModal() }
    a.beginSheetModal(for: w) { NSApp.stopModal(withCode: $0) }
    return NSApp.runModal(for: a.window)
}

/// Session-level agent actions shared by tabs and the sidebar.
@MainActor
enum AgentActions {
    static var delegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    static func rename(_ sid: String) {
        let cur = AppModel.shared.session(sid)?.title ?? ""
        guard let t = prompt("Rename", "Leave empty to name it from the task automatically.", initial: cur) else { return }
        Task { await AppModel.shared.call("session.rename", .obj(["id": .string(sid), "title": .string(t)])) }
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

    static func copyContext(_ sid: String) {
        Task {
            guard let t = await AppModel.shared.call("session.context", .obj(["id": .string(sid)]))?.string else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
            Banner.show("Context copied")
        }
    }
}

/// A one-field question (rename, go to line…).
@MainActor
func prompt(_ title: String, _ info: String, initial: String = "") -> String? {
    let a = NSAlert(); a.messageText = title; a.informativeText = info
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); f.stringValue = initial
    a.accessoryView = f; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = f
    return runAsSheet(a) == .alertFirstButtonReturn ? f.stringValue : nil
}
