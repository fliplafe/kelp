import AppKit
import SwiftUI
import Core
import WorkbenchKit

/// What the sidebar's menus and keys do.
extension SidebarController {
    // MARK: actions

    func newWorkspace(_ repo: String) { Workbench.newWorkspace(repo: repo) }
    func refreshCell(_ key: String) {
        guard let n = node(key) else { return }
        let row = outline.row(forItem: n)
        if row >= 0 { (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.update() }
    }

    /// Inline rename, like Finder.
    func startRename(_ workspace: String) {
        guard let n = node("w:" + workspace) else { return }
        let row = outline.row(forItem: n)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell else { return }
        renaming = workspace
        cell.beginEditing(delegate: self)
    }
    func controlTextDidEndEditing(_ n: Notification) {
        guard let id = renaming, let field = n.object as? NSTextField else { return }
        renaming = nil
        field.isEditable = false; field.drawsBackground = false
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != AppModel.shared.worktree(id)?.displayName {
            Task { await AppModel.shared.call(WorktreeNote(id: id, note: name)) }
        } else { refreshCell("w:" + id) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        card.close()
        guard let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
        let m = AppModel.shared
        let picked = outline.selectedRowIndexes
        if picked.count > 1, picked.contains(outline.clickedRow) {
            bulkMenu(menu, picked.compactMap { outline.item(atRow: $0) as? Node }); return
        }
        switch n.kind {
        case .project(let id):
            guard let r = m.repo(id) else { return }
            if !FileManager.default.fileExists(atPath: r.path) {
                menu.add(String(localized: "Locate…")) { WorkspaceActions.relocate(r) }
                menu.add(String(localized: "Remove from Kelp…")) { WorkspaceActions.removeProject(r) }
                return
            }
            menu.add(String(localized: "New Workspace")) { [weak self] in self?.newWorkspace(id) }
            menu.add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
            menu.addItem(.separator())
            if RemoteHost.of(r.path) == nil { menu.add(String(localized: "Remove Clean Worktrees…")) { WorkspaceActions.removeCleanWorktrees(r) } }
            menu.add(String(localized: "Remove Project…")) { WorkspaceActions.removeProject(r) }
        case .section: return
        case .needs(let sid):
            menu.add(String(localized: "Show")) { Workbench.focus(session: sid) }
            if m.session(sid)?.unread == true {
                menu.add(String(localized: "Mark as Read")) { Task { await AppModel.shared.call("session.markRead", .obj(["id": .string(sid)])) } }
            }
        case .workspace(let id):
            guard let w = m.worktree(id) else { return }
            let pinned = Self.pinned.contains(id)
            menu.add(pinned ? String(localized: "Unpin") : String(localized: "Pin to Top")) { [weak self] in
                Self.pinned = pinned ? Self.pinned.filter { $0 != id } : Self.pinned + [id]; self?.refresh()
            }
            menu.add(String(localized: "Rename")) { [weak self] in self?.startRename(id) }
            menu.add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
            menu.add(String(localized: "Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(w.path, forType: .string) }
            WorkspaceActions.addOpenIn(to: menu, path: w.path)
            menu.addItem(.separator())
            if w.path == m.repo(w.repoId)?.path {
                // A desk: archiving pauses its agents and keeps its tabs (Window › Archived Workspaces brings it back);
                // with ⌥ the item closes it instead, ending its agents. The project's folder is untouched either way.
                let more = m.worktrees.filter { $0.repoId == w.repoId && $0.path == w.path && !$0.archived }.count > 1
                let archive = menu.add(String(localized: "Archive")) { WorkspaceActions.archive(w) }
                archive.isEnabled = more
                let close = menu.add(String(localized: "Close Workspace")) { WorkspaceActions.close(w) }
                close.isAlternate = true; close.keyEquivalentModifierMask = .option; close.isEnabled = more
            } else {
                menu.add(String(localized: "Archive")) { WorkspaceActions.archive(w) }
                menu.add(String(localized: "Delete Workspace & Branch…")) { WorkspaceActions.delete(w) }
            }
        case .agent(let sid):
            menu.add(String(localized: "Show")) { Workbench.focus(session: sid) }
            menu.add(String(localized: "Rename…")) { AgentActions.rename(sid) }
            menu.add(String(localized: "Restart")) { AgentActions.restart(sid) }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy Context")) { AgentActions.copyContext(sid) }
            menu.setSubmenu(AgentActions.handoffMenu(sid), for: menu.addItem(withTitle: String(localized: "Hand Off to"), action: nil, keyEquivalent: ""))
            if m.session(sid)?.unread == false {
                menu.add(String(localized: "Mark as Unread")) { Task { await AppModel.shared.call("session.markUnread", .obj(["id": .string(sid)])) } }
            }
            menu.addItem(.separator())
            menu.add(String(localized: "Stop")) { Task { await AppModel.shared.call("session.kill", .obj(["id": .string(sid)])) } }
        }
    }
}
