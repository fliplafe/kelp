import AppKit
import Core

/// Entry points everything uses to act on the window: open URIs, switch workspaces, focus agents.
@MainActor
extension Workbench {
    static var window: MainWindowController? { (NSApp.delegate as? AppDelegate)?.main }
    /// The editor area of the workspace on screen.
    static var editor: EditorArea? { window?.editors.current }

    static func show(workspace id: String) {
        guard shared.workspaceId != id || editor == nil else { return }
        shared.workspaceId = id
        Perf.measure("workspace") { window?.showWorkspace(id) }
    }

    static func open(_ uri: String, split: SplitDirection? = nil, workspace: String? = nil) {
        if let workspace, workspace != shared.workspaceId { show(workspace: workspace) }
        if shared.workspaceId == nil, let first = AppModel.shared.worktrees.first { show(workspace: first.id) }
        editor?.open(uri, split: split)
    }

    static func focus(session id: String) {
        guard let s = AppModel.shared.session(id) else { return }
        if let w = s.worktreeId, w != shared.workspaceId { show(workspace: w) }
        editor?.focus(session: id)
        if s.unread { Task { await AppModel.shared.call("session.markRead", .obj(["id": .string(id)])) } }
    }

    /// Workspaces in sidebar order (⌃1–9, ⌃⌘↑ / ↓).
    static var workspacesInOrder: [Worktree] { AppModel.shared.repos.flatMap { AppModel.shared.workspaces(of: $0) } }

    static func showWorkspace(offset: Int) {
        let all = workspacesInOrder
        guard !all.isEmpty else { NSSound.beep(); return }
        let i = all.firstIndex { $0.id == shared.workspaceId }.map { ($0 + offset + all.count) % all.count } ?? 0
        show(workspace: all[i].id)
    }

    static func showWorkspace(number n: Int) {
        let all = workspacesInOrder
        guard all.indices.contains(n - 1) else { NSSound.beep(); return }
        show(workspace: all[n - 1].id)
    }

    /// ⇧⌘U: the next agent that asked something or finished, wherever it is.
    static func showNextNeedingAttention() {
        let current = editor?.layout.focusedGroup?.selectedTab.map(\.uri).flatMap { TabURI.scheme($0) == "session" ? TabURI.body($0) : nil }
        guard let s = AttentionQueue.next(after: current) else { NSSound.beep(); return }
        focus(session: s.id)
    }

    static func closeTab(uri: String) {
        guard let e = editor, let t = e.layout.tab(uri: uri) else { return }
        e.closeTab(t.id)
    }

    static func addProject() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose a git repository"; p.prompt = "Add Project"
        let chosen = { (r: NSApplication.ModalResponse) in
            guard r == .OK, let u = p.url else { return }
            addProject(path: u.path)
        }
        // A sheet on the window, not an app-modal panel that stops everything else.
        if let w = NSApp.mainWindow ?? NSApp.keyWindow { p.beginSheetModal(for: w, completionHandler: chosen) } else { p.begin(completionHandler: chosen) }
    }

    /// A folder dropped on the Dock icon or the sidebar, `open -a Krill .`, or picked in Add Project: its project on screen
    /// (added first if it's new; a folder inside a repository adds the repository).
    static func addProject(path: String) {
        Task {
            let m = AppModel.shared
            for _ in 0..<50 where !m.connected { try? await Task.sleep(for: .milliseconds(100)) }   // opened at launch
            guard let r = await m.call("repo.add", .obj(["path": .string(path)])), let rid = r["id"]?.string else { return }
            await m.refresh()
            let ws = m.repo(rid).map(m.workspaces(of:)) ?? []
            if let w = ws.first(where: { $0.id == shared.workspaceId }) ?? ws.first { show(workspace: w.id) }
        }
    }

    /// New isolated workspace in the project on screen (or the first one).
    static func newWorkspace(repo: String? = nil) {
        Task {
            // Right after launch the project list may not be in yet: ⌘N must not turn into "Add Project".
            let m = AppModel.shared
            for _ in 0..<50 where !m.connected { try? await Task.sleep(for: .milliseconds(100)) }
            if m.repos.isEmpty { await m.refresh() }
            guard let rid = repo ?? m.worktree(shared.workspaceId)?.repoId ?? m.repos.first?.id else { addProject(); return }
            guard let w = await AppModel.shared.call("workspace.create", .obj(["repoId": .string(rid)])), let id = w["id"]?.string else { return }
            await AppModel.shared.refresh()
            show(workspace: id)
        }
    }
}

/// IDE actions agents ask for through the daemon (`krill open`, MCP tools).
@MainActor
enum UIRequests {
    static func handle(_ p: JSONValue) {
        switch p["action"]?.string {
        case "open":
            guard let uri = p["uri"]?.string else { return }
            let split = p["split"]?.string.flatMap(SplitDirection.init(rawValue:))
            Workbench.open(uri, split: split, workspace: p["worktreeId"]?.string)
            NSApp.activate()
        case "command":
            guard let id = p["id"]?.string else { return }
            if id == "extensions.reload" { ExtensionRegistry.shared.reload(); return }
            guard let c = ExtensionRegistry.shared.command(id) else { Banner.show("Unknown command \(id)", style: .error); return }
            if case .object(let args)? = p["args"] { c.run(args) } else { c.run([:]) }
        default: break
        }
    }
}

@MainActor
enum WorkspaceActions {
    private static let editors = [("VS Code", "com.microsoft.VSCode"), ("Cursor", "com.todesktop.230313mzl4w4u92"), ("Zed", "dev.zed.Zed"),
                                  ("Xcode", "com.apple.dt.Xcode"), ("Terminal", "com.apple.Terminal")]

    /// "Open in VS Code"… for whatever editors this Mac has, like "Open With" in Finder.
    static func addOpenIn(to menu: NSMenu, path: @escaping @MainActor () -> String?, prefix: String = "Open in ") {
        for (name, bundle) in editors {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { continue }
            let i = menu.add(prefix + name) {
                guard var p = path() else { NSSound.beep(); return }
                var dir: ObjCBool = false
                // Terminal would run a file as a script: it gets the file's folder.
                if bundle == "com.apple.Terminal", FileManager.default.fileExists(atPath: p, isDirectory: &dir), !dir.boolValue { p = (p as NSString).deletingLastPathComponent }
                NSWorkspace.shared.open([URL(fileURLWithPath: p)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
            i.image = NSWorkspace.shared.icon(forFile: app.path).resized(16)
        }
    }
    static func addOpenIn(to menu: NSMenu, path: String) { addOpenIn(to: menu, path: { path }) }

    /// The file in the focused tab, else the workspace's folder (Xcode's "Show in Finder" works on the selection).
    static func revealCurrent() {
        if let f = Workbench.editor?.focusedContent as? FileTab { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]); return }
        guard let w = AppModel.shared.worktree(Workbench.shared.workspaceId) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)])
    }

    static func delete(_ w: Worktree) {
        Task {
            let dirty = await AppModel.shared.call("worktree.dirty", .obj(["id": .string(w.id)]))?.bool ?? false
            let a = NSAlert(); a.messageText = "Delete “\(w.displayName)” and its branch?"
            a.informativeText = dirty ? "It has uncommitted changes that will be lost." : "The checkout and branch \(w.branch) are removed. Running agents stop."
            a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel"); a.alertStyle = dirty ? .critical : .warning
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            if Workbench.shared.workspaceId == w.id, let main = AppModel.shared.worktrees.first(where: { $0.repoId == w.repoId && $0.id != w.id }) {
                Workbench.show(workspace: main.id)
            }
            await AppModel.shared.call("worktree.remove", .obj(["id": .string(w.id), "force": .bool(dirty)]))
        }
    }

    /// A desk: its agents end, the folder stays. Asks only when agents are running there.
    static func close(_ w: Worktree) {
        // The project's last workspace stays (removing the project is a separate, deliberate action).
        guard AppModel.shared.worktrees.filter({ $0.repoId == w.repoId && !$0.archived }).count > 1 else { NSSound.beep(); return }
        let running = AppModel.shared.sessions.filter { $0.worktreeId == w.id && $0.status != .exited && $0.status != .hibernated }
        Task {
            if !running.isEmpty {
                let a = NSAlert(); a.messageText = "Close “\(w.displayName)”?"
                a.informativeText = "\(running.count) running \(running.count == 1 ? "agent stops" : "agents stop"). Files in the project are not touched."
                a.addButton(withTitle: "Close"); a.addButton(withTitle: "Cancel")
                guard await runSheet(a) == .alertFirstButtonReturn else { return }
            }
            if Workbench.shared.workspaceId == w.id, let other = AppModel.shared.worktrees.first(where: { $0.repoId == w.repoId && $0.id != w.id }) {
                Workbench.show(workspace: other.id)
            }
            await AppModel.shared.call("worktree.remove", .obj(["id": .string(w.id)]))
            await AppModel.shared.refresh()
        }
    }

    static func removeProject(_ r: Repo) {
        let a = NSAlert(); a.messageText = "Remove “\(r.name)” from Krill?"; a.informativeText = "The repository on disk is not touched."
        a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            await AppModel.shared.call("repo.remove", .obj(["id": .string(r.id)]))
        }
    }
}

@MainActor
enum PRActions {
    /// Pushes and opens a PR; title and body are drafted on-device from the branch's commits.
    static func create(worktree wid: String) {
        let a = NSAlert(); a.messageText = "Create a pull request?"
        a.informativeText = "Pushes \(AppModel.shared.worktree(wid)?.branch ?? "the branch") and opens a PR with a drafted title and description."
        a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            guard let r = await AppModel.shared.call("github.pr-create", .obj(["worktreeId": .string(wid)])) else { return }
            let url = r.string ?? r["url"]?.string ?? ""
            Banner.show(url.isEmpty ? "Pull request created" : "Pull request created: \(url)")
            if let u = URL(string: url), !url.isEmpty { Workbench.open(u.absoluteString) }
        }
    }
}
