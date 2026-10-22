import AppKit
import Core
import WorkbenchKit

extension Builtins {
    /// The shell's own actions (sidebar and inspector, panes, tabs, workspaces, text size, the Run menu, help) as commands,
    /// so the menu bar, Settings › Keyboard, the palette and agents (`kelp run <id>`) reach them the same way.
    static let workbench = Builtin("kelp.workbench", "Window & Workbench", "Panes, tabs, workspaces, the sidebar and inspector: the commands of the window.",
                                   icon: "macwindow", essential: true) { app in
        var c = Contributions()
        c.commands = [
            cmd("workbench.openSettings", "Settings…", "cmd+,") { SettingsWindow.show() },
            cmd("workbench.openExtensions", "Extensions…") { SettingsWindow.show(section: "extensions") },
            cmd("workbench.restartService", "Restart Background Service…") { restartService(app) },
            cmd("workbench.toggleSidebar", "Show Sidebar", "cmd+0") { Workbench.window?.toggleSidebarPanel() },
            cmd("workbench.toggleInspector", "Show Inspector", "opt+cmd+0") { Workbench.window?.toggleInspectorPanel() },
            cmd("workbench.toggleFocusMode", "Focus Mode", "ctrl+cmd+z") { Workbench.window?.toggleFocusMode() },
            CommandSpec(id: "workbench.showPanel", title: "Show Panel") { a in
                if let p = a["panel"]?.string { Workbench.window?.showInspector(panel: p) }
            },
            cmd("workbench.commandPalette", "Command Palette…", "shift+cmd+p") { QuickOpen.shared.show(commandsOnly: true) },
            cmd("workbench.scratch", "Scratch", "ctrl+opt+cmd+k") { ScratchWindow.shared.toggle() },
            cmd("view.biggerText", "Bigger Text", "cmd+plus") { zoomText(app, 1) },
            cmd("view.smallerText", "Smaller Text", "cmd+-") { zoomText(app, -1) },
            cmd("view.defaultTextSize", "Default Text Size") { zoomText(app, nil) },
            cmd("view.maximizePane", "Maximize Pane", "shift+cmd+return") { editor?.toggleZoom() },
            cmd("view.equalizePanes", "Equalize Panes") { editor?.equalizePanes() },
            cmd("view.nextPane", "Next Pane", "cmd+]") { editor?.focusGroup(1) },
            cmd("view.previousPane", "Previous Pane", "cmd+[") { editor?.focusGroup(-1) },
            // ⌥⌘ arrows, as Ghostty moves between splits
            cmd("view.paneLeft", "Pane on the Left", "opt+cmd+left") { editor?.focusGroup(toward: .minX) },
            cmd("view.paneRight", "Pane on the Right", "opt+cmd+right") { editor?.focusGroup(toward: .maxX) },
            cmd("view.paneAbove", "Pane Above", "opt+cmd+up") { editor?.focusGroup(toward: .maxY) },
            cmd("view.paneBelow", "Pane Below", "opt+cmd+down") { editor?.focusGroup(toward: .minY) },
            cmd("editor.nextTab", "Next Tab", "shift+cmd+]") { editor?.cycleTab(1) },
            cmd("editor.previousTab", "Previous Tab", "shift+cmd+[") { editor?.cycleTab(-1) },
            // ⌘W: the focused tab; in a workspace with nothing open, the workspace itself.
            cmd("editor.closeTab", "Close Tab", "cmd+w") {
                guard let e = editor else { return }
                if e.focusedContent == nil, let w = e.worktree { WorkspaceActions.close(w) } else { e.closeFocusedTab() }
            },
            cmd("workspace.new", "New Workspace", "cmd+n") { Workbench.newWorkspace() },
            cmd("workspace.addProject", "Add Project…", "cmd+o") { Workbench.addProject() },
            cmd("workspace.cloneRepository", "Clone Repository…") { CloneSheet.show() },
            cmd("workspace.addRemote", "Open over SSH…") { RemoteSheet.show() },
            cmd("workspace.revealInFinder", "Reveal in Finder", "opt+cmd+r") { WorkspaceActions.revealCurrent() },
            cmd("workspace.close", "Close Workspace", "shift+cmd+w") { if let w = editor?.worktree { WorkspaceActions.close(w) } },
            // ⌃Tab walks the workspaces used last (⌃⇧Tab: `{"by": -1}`).
            CommandSpec(id: "workspace.switch", title: "Switch Workspace", key: "ctrl+tab") { a in WorkspaceSwitcher.shared.step(a["by"]?.int ?? 1) },
            cmd("workspace.next", "Next Workspace", "ctrl+cmd+down") { Workbench.showWorkspace(offset: 1) },
            cmd("workspace.previous", "Previous Workspace", "ctrl+cmd+up") { Workbench.showWorkspace(offset: -1) },
            // Back and forward through the workspaces you visited.
            cmd("workspace.back", "Back", "ctrl+cmd+left") { Workbench.goBack(-1) },
            cmd("workspace.forward", "Forward", "ctrl+cmd+right") { Workbench.goBack(1) },
            // The Run menu: the project's commands from .kelp.yaml (`{"name": "lint"}` runs another one).
            CommandSpec(id: "scripts.run", title: "Run", key: "cmd+r") { a in ScriptsMenu.shared.run(a["name"]?.string ?? "run") },
            cmd("scripts.test", "Test", "cmd+u") { ScriptsMenu.shared.run("test") },
            cmd("scripts.stop", "Stop", "cmd+.") { ScriptsMenu.shared.stop() },
            cmd("scripts.edit", "Edit Commands…") { ScriptsMenu.shared.edit() },
            cmd("help.guide", "How Kelp Works", "cmd+?") { Workbench.open(TabURI.file(Help.file.path)) },
            cmd("help.extensionGuide", "Writing Extensions") {
                Workbench.open(TabURI.file(ExtensionRegistry.userDir.appendingPathComponent("EXTENSIONS.md").path))
            }
        ]
        // Like VS Code's openEditorAtIndex1…9: one id per number, so each can be rebound.
        c.commands += (1...9).map { n in cmd("editor.tab.\(n)", "Tab \(n)", "cmd+\(n)") { editor?.selectTab(index: n - 1) } }
        c.commands += (1...9).map { n in cmd("workspace.select.\(n)", "Workspace \(n)", "ctrl+\(n)") { Workbench.showWorkspace(number: n) } }
        return c
    }

    /// Terminal and editor text zoom together, like a browser; the settings stay the one source.
    private static func zoomText(_ app: AppModel, _ step: Double?) {
        let s = app.settings
        for key in ["terminal.fontSize", "editor.fontSize"] {
            s.set(key, .double(step.map { min(40, max(8, (s.number(key) ?? 13) + $0)) } ?? 13))
        }
    }

    private static func restartService(_ app: AppModel) {
        let a = NSAlert(); a.messageText = String(localized: "Restart the background service?")
        a.informativeText = String(localized: "Running agent sessions end. Workspaces, history and settings are kept.")
        a.addButton(withTitle: String(localized: "Restart")); a.addButton(withTitle: String(localized: "Cancel"))
        Task { if await runSheet(a) == .alertFirstButtonReturn { await app.restartDaemon() } }
    }
}
