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

    static func closeTab(uri: String) {
        guard let e = editor, let t = e.layout.tab(uri: uri) else { return }
        e.closeTab(t.id)
    }

    static func addProject() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose a git repository"; p.prompt = "Add Project"
        guard p.runModal() == .OK, let u = p.url else { return }
        Task {
            guard let r = await AppModel.shared.call("repo.add", .obj(["path": .string(u.path)])), let rid = r["id"]?.string else { return }
            await AppModel.shared.refresh()
            if let main = AppModel.shared.worktrees.first(where: { $0.repoId == rid && $0.path == r["path"]?.string }) { show(workspace: main.id) }
        }
    }

    /// New isolated workspace in the project on screen (or the first one).
    static func newWorkspace(repo: String? = nil) {
        guard let rid = repo ?? AppModel.shared.worktree(shared.workspaceId)?.repoId ?? AppModel.shared.repos.first?.id else { addProject(); return }
        Task {
            guard let w = await AppModel.shared.call("worktree.create", .obj(["repoId": .string(rid)])), let id = w["id"]?.string else { return }
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
            Attribution.reset(worktree: w.id)
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
