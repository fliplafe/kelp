import AppKit
import Core
import WorkbenchKit

extension Builtins {
    /// The shell's own actions (sidebar and inspector, panes, tabs, workspaces, text size, the Run menu, help) as commands,
    /// so the menu bar, Settings › Keyboard, the palette and agents (`kelp run <id>`) reach them the same way.
    static let workbench = Builtin("kelp.workbench", "Window & Workbench", "Panes, tabs, workspaces, the sidebar and inspector: the commands of the window.",
                                   icon: "macwindow", essential: true) {
        let ext = "kelp.workbench"
        var c = Contributions()
        c.commands = [
            cmd(ext, "workbench.openSettings", "Settings…", "cmd+,") { SettingsWindow.show() },
            cmd(ext, "workbench.openExtensions", "Extensions…") { SettingsWindow.show(section: "extensions") },
            cmd(ext, "workbench.restartService", "Restart Background Service…") { restartService() },
            cmd(ext, "workbench.toggleSidebar", "Show Sidebar", "cmd+0") { Workbench.window?.toggleSidebarPanel() },
            cmd(ext, "workbench.toggleInspector", "Show Inspector", "opt+cmd+0") { Workbench.window?.toggleInspectorPanel() },
            cmd(ext, "workbench.toggleFocusMode", "Focus Mode", "ctrl+cmd+z") { Workbench.window?.toggleFocusMode() },
            CommandSpec(id: "workbench.showPanel", title: "Show Panel", extensionId: ext) { a in
                if let p = a["panel"]?.string { Workbench.window?.showInspector(panel: p) }
            },
            cmd(ext, "workbench.commandPalette", "Command Palette…", "shift+cmd+p") { QuickOpen.shared.show(commandsOnly: true) },
            cmd(ext, "workbench.scratch", "Scratch", "ctrl+opt+cmd+k") { ScratchWindow.shared.toggle() },
            cmd(ext, "view.biggerText", "Bigger Text", "cmd+plus") { zoomText(1) },
            cmd(ext, "view.smallerText", "Smaller Text", "cmd+-") { zoomText(-1) },
            cmd(ext, "view.defaultTextSize", "Default Text Size") { zoomText(nil) },
            cmd(ext, "view.maximizePane", "Maximize Pane", "shift+cmd+return") { editor?.toggleZoom() },
            cmd(ext, "view.equalizePanes", "Equalize Panes") { editor?.equalizePanes() },
            cmd(ext, "view.nextPane", "Next Pane", "cmd+]") { editor?.focusGroup(1) },
            cmd(ext, "view.previousPane", "Previous Pane", "cmd+[") { editor?.focusGroup(-1) },
            // ⌥⌘ arrows, as Ghostty moves between splits
            cmd(ext, "view.paneLeft", "Pane on the Left", "opt+cmd+left") { editor?.focusGroup(toward: .minX) },
            cmd(ext, "view.paneRight", "Pane on the Right", "opt+cmd+right") { editor?.focusGroup(toward: .maxX) },
            cmd(ext, "view.paneAbove", "Pane Above", "opt+cmd+up") { editor?.focusGroup(toward: .maxY) },
            cmd(ext, "view.paneBelow", "Pane Below", "opt+cmd+down") { editor?.focusGroup(toward: .minY) },
            cmd(ext, "editor.nextTab", "Next Tab", "shift+cmd+]") { editor?.cycleTab(1) },
            cmd(ext, "editor.previousTab", "Previous Tab", "shift+cmd+[") { editor?.cycleTab(-1) },
            // ⌘W: the focused tab; in a workspace with nothing open, the workspace itself.
            cmd(ext, "editor.closeTab", "Close Tab", "cmd+w") {
                guard let e = editor else { return }
                if e.focusedContent == nil, let w = e.worktree { WorkspaceActions.close(w) } else { e.closeFocusedTab() }
            },
            cmd(ext, "workspace.new", "New Workspace", "cmd+n") { Workbench.newWorkspace() },
            cmd(ext, "workspace.addProject", "Add Project…", "cmd+o") { Workbench.addProject() },
            cmd(ext, "workspace.cloneRepository", "Clone Repository…") { NewProjectSheet.show(.clone) },
            cmd(ext, "workspace.addRemote", "Open over SSH…") { NewProjectSheet.show(.remote) },
            cmd(ext, "workspace.revealInFinder", "Reveal in Finder", "opt+cmd+r") { WorkspaceActions.revealCurrent() },
            cmd(ext, "workspace.close", "Close Workspace", "shift+cmd+w") { if let w = editor?.worktree { WorkspaceActions.close(w) } },
            // ⌃Tab walks the workspaces used last (⌃⇧Tab: `{"by": -1}`).
            CommandSpec(id: "workspace.switch", title: "Switch Workspace", extensionId: ext, key: "ctrl+tab") { a in WorkspaceSwitcher.shared.step(a["by"]?.int ?? 1) },
            cmd(ext, "workspace.next", "Next Workspace", "ctrl+cmd+down") { Workbench.showWorkspace(offset: 1) },
            cmd(ext, "workspace.previous", "Previous Workspace", "ctrl+cmd+up") { Workbench.showWorkspace(offset: -1) },
            // Back and forward through the workspaces you visited.
            cmd(ext, "workspace.back", "Back", "ctrl+cmd+left") { Workbench.goBack(-1) },
            cmd(ext, "workspace.forward", "Forward", "ctrl+cmd+right") { Workbench.goBack(1) },
            // The Run menu: the project's commands from .kelp.yaml (`{"name": "lint"}` runs another one).
            CommandSpec(id: "scripts.run", title: "Run", extensionId: ext, key: "cmd+r") { a in ScriptsMenu.shared.run(a["name"]?.string ?? "run") },
            cmd(ext, "scripts.test", "Test", "cmd+u") { ScriptsMenu.shared.run("test") },
            cmd(ext, "scripts.stop", "Stop", "cmd+.") { ScriptsMenu.shared.stop() },
            cmd(ext, "scripts.edit", "Edit Commands…") { ScriptsMenu.shared.edit() },
            cmd(ext, "help.guide", "How Kelp Works", "cmd+?") { Workbench.open(TabURI.file(Help.file.path)) },
            cmd(ext, "help.extensionGuide", "Writing Extensions") {
                Workbench.open(TabURI.file(ExtensionRegistry.userDir.appendingPathComponent("EXTENSIONS.md").path))
            }
        ]
        // Like VS Code's openEditorAtIndex1…9: one id per number, so each can be rebound.
        c.commands += (1...9).map { n in cmd(ext, "editor.tab.\(n)", "Tab \(n)", "cmd+\(n)") { editor?.selectTab(index: n - 1) } }
        c.commands += (1...9).map { n in cmd(ext, "workspace.select.\(n)", "Workspace \(n)", "ctrl+\(n)") { Workbench.showWorkspace(number: n) } }
        return c
    }

    /// Terminal and editor text zoom together, like a browser; the settings stay the one source.
    private static func zoomText(_ step: Double?) {
        let s = SettingsStore.shared
        for key in ["terminal.fontSize", "editor.fontSize"] {
            s.set(key, .double(step.map { min(40, max(8, (s.number(key) ?? 13) + $0)) } ?? 13))
        }
    }

    private static func restartService() {
        let a = NSAlert(); a.messageText = String(localized: "Restart the background service?"); a.informativeText = String(localized: "Running agent sessions end. Workspaces, history and settings are kept.")
        a.addButton(withTitle: String(localized: "Restart")); a.addButton(withTitle: String(localized: "Cancel"))
        Task { if await runSheet(a) == .alertFirstButtonReturn { await AppModel.shared.restartDaemon() } }
    }
}
