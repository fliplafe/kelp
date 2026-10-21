import AppKit
import Core
import WorkbenchKit

/// Entry points everything uses to act on the window: open URIs, switch workspaces, focus agents.
@MainActor
extension Workbench {
    static var window: MainWindowController? { (NSApp.delegate as? AppDelegate)?.main }
    /// The editor area with the keyboard: the Scratch panel's while it's key, else the workspace on screen's.
    static var editor: EditorArea? { keyArea ?? window?.editors.current }
    /// An editor area that is a window's whole content (the Scratch panel) and has the keys.
    private static var keyArea: EditorArea? { NSApp.keyWindow?.contentViewController as? EditorArea }

    static func show(workspace id: String) { show(workspace: id, remember: true) }

    private static func show(workspace id: String, remember: Bool) {
        guard shared.workspaceId != id || window?.editors.current == nil else { return }
        shared.workspaceId = id
        if remember { shared.history.visit(id) }
        window?.showWorkspace(id)
    }

    /// ⌃⌘← / ⌃⌘→: the workspace shown before / after this one (closed ones are skipped).
    static func goBack(_ step: Int) {
        guard let i = visit(step) else { NSSound.beep(); return }
        show(workspace: shared.history.go(to: i), remember: false)
    }

    /// Where Back (-1) / Forward (1) would go: nil when there's nothing that way (the title bar's arrows grey out).
    static func visit(_ step: Int) -> Int? {
        shared.history.target(step, current: shared.workspaceId) { AppModel.shared.worktree($0) != nil }
    }

    static func open(_ uri: String, split: SplitDirection? = nil, workspace: String? = nil, focus: Bool = true) {
        if let k = keyArea, workspace == nil || workspace == k.workspaceId { k.open(uri, split: split, focus: focus); return }
        if let workspace, workspace != shared.workspaceId { show(workspace: workspace) }
        if shared.workspaceId == nil, let first = AppModel.shared.worktrees.first { show(workspace: first.id) }
        window?.editors.current?.open(uri, split: split, focus: focus)
    }

    static func focus(session id: String) {
        guard let s = AppModel.shared.session(id) else { return }
        if let k = keyArea, s.worktreeId == k.workspaceId { k.focus(session: id) } else {
            if let w = s.worktreeId, w != shared.workspaceId { show(workspace: w) }
            window?.editors.current?.focus(session: id)
        }
        // Opening a finished agent is reading it; a question stays marked until it's answered (typing clears it).
        if s.unread, s.status == .done { Task { await AppModel.shared.call(SessionMarkRead(id: id)) } }
    }

    /// Workspaces in sidebar order (⌃1–9, ⌃⌘↑ / ↓).
    static var workspacesInOrder: [Worktree] { AppModel.shared.projects.flatMap { AppModel.shared.workspaces(of: $0) } }

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
        guard let e = [keyArea, window?.editors.current].compactMap({ $0 }).first(where: { $0.layout.tab(uri: uri) != nil }),
              let t = e.layout.tab(uri: uri) else { return }
        e.closeTab(t.id)
    }

    static func addProject() {
        // A new folder made here is a new project (repo.add runs `git init` in an empty one). Clone and SSH are their own commands.
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.message = String(localized: "Choose a project folder, or make a new one"); p.prompt = String(localized: "Add Project")
        let chosen = { (r: NSApplication.ModalResponse) in
            guard r == .OK, let u = p.url else { return }
            addProject(path: u.path)
        }
        // A sheet on the window, not an app-modal panel that stops everything else.
        if let w = NSApp.mainWindow ?? NSApp.keyWindow { p.beginSheetModal(for: w, completionHandler: chosen) } else { p.begin(completionHandler: chosen) }
    }

    /// A folder dropped on the Dock icon or the sidebar, `open -a Kelp .`, or picked in Add Project: its project on screen
    /// (added first if it's new; a folder inside a repository adds the repository).
    static func addProject(path: String) {
        Task {
            let m = AppModel.shared
            await m.waitForConnection()   // opened at launch
            guard let rid = await m.call(RepoAdd(path: path))?.id else { return }
            await m.refresh()
            let ws = m.repo(rid).map(m.workspaces(of:)) ?? []
            if let w = ws.first(where: { $0.id == shared.workspaceId }) ?? ws.first { show(workspace: w.id) }
        }
    }

    /// Files and folders from Finder (dropped on the window or the Dock icon, `open -a Kelp <path>`): a folder becomes a
    /// project, a file opens as a tab (`open`: in that editor area, else wherever ⌘O would).
    static func open(files urls: [URL], with open: @MainActor (String) -> Void = { Workbench.open($0) }) {
        for u in urls {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
            if dir.boolValue { addProject(path: u.path) } else { open(TabURI.file(u.path)) }
        }
    }

    /// The files a drag carries (from Finder or the Files panel).
    static func files(_ s: NSDraggingInfo) -> [URL] {
        s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// New isolated workspace in the project on screen (or the first one).
    static func newWorkspace(repo: String? = nil) {
        Task {
            // Right after launch the project list may not be in yet: ⌘N must not turn into "Add Project".
            let m = AppModel.shared
            await m.waitForConnection()
            guard let rid = repo ?? m.worktree(shared.workspaceId)?.repoId ?? m.repos.first?.id else { addProject(); return }
            guard let id = await AppModel.shared.call(WorkspaceCreate(repoId: rid))?.id else { return }
            await AppModel.shared.refresh()
            show(workspace: id)
        }
    }
}

/// `kelp://` links (from a browser, a script, another app). Looking things up is free; adding a project asks first.
@MainActor
enum KelpLinks {
    static func handle(_ url: URL) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = url.pathComponents.dropFirst().first ?? ""
        switch url.host {
        case "workspace" where AppModel.shared.worktree(id) != nil: Workbench.show(workspace: id)
        case "session" where AppModel.shared.session(id) != nil: Workbench.focus(session: id)
        case "open":
            guard let path = q.first(where: { $0.name == "path" })?.value.map({ ($0 as NSString).expandingTildeInPath }),
                  FileManager.default.fileExists(atPath: path) else { Banner.show(String(localized: "Kelp can't find the file in that link."), style: .error); return }
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &dir)
            if !dir.boolValue {
                let line = q.first { $0.name == "line" }?.value.flatMap(Int.init)
                let w = AppModel.shared.worktrees.filter { path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
                Workbench.open(TabURI.file(path) + (line.map { "#L\($0)" } ?? ""), workspace: w?.id)
            } else if AppModel.shared.repos.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                Workbench.addProject(path: path)   // already a project: just shows it
            } else {
                let a = NSAlert(); a.messageText = String(localized: "Add “\((path as NSString).lastPathComponent)” to Kelp?")
                a.informativeText = String(localized: "A link asked to open \(path) as a project.")
                a.addButton(withTitle: String(localized: "Add Project")); a.addButton(withTitle: String(localized: "Cancel"))
                Task { if await runSheet(a) == .alertFirstButtonReturn { Workbench.addProject(path: path) } }
            }
        default: Banner.show(String(localized: "Kelp doesn't know the link \(url.absoluteString)."), style: .error)
        }
        NSApp.activate()
    }
}

/// IDE actions agents ask for through the daemon (`kelp open`, `kelp ui`). They never pull Kelp to the front or
/// switch the workspace on screen unless asked (`--focus`): a tab for another workspace waits there.
@MainActor
enum UIRequests {
    static func handle(_ e: UIEvent) {
        switch e.action {
        case "open":
            guard let uri = e.uri else { return }
            let split = e.split.flatMap(SplitDirection.init(rawValue:))
            let focus = e.focus == true
            if let w = e.worktreeId, w != Workbench.shared.workspaceId, !focus, Workbench.shared.workspaceId != nil {
                Workbench.window?.editors.openInBackground(uri, workspace: w)
                return
            }
            Workbench.open(uri, split: split, workspace: e.worktreeId)
            if focus { NSApp.activate() }
        case "command":
            guard let id = e.id else { return }
            if id == "extensions.reload" { ExtensionRegistry.shared.reload(); return }
            guard let c = ExtensionRegistry.shared.command(id) else { Banner.show(String(localized: "Unknown command \(id)"), style: .error); return }
            if case .object(let args)? = e.args { c.run(args) } else { c.run([:]) }
        default: break
        }
    }
}

@MainActor
enum WorkspaceActions {
    private static let editors = [("VS Code", "com.microsoft.VSCode"), ("Cursor", "com.todesktop.230313mzl4w4u92"), ("Windsurf", "com.exafunction.windsurf"),
                                  ("Zed", "dev.zed.Zed"), ("Sublime Text", "com.sublimetext.4"), ("Xcode", "com.apple.dt.Xcode"),
                                  ("Fork", "com.DanPristupov.Fork"), ("Tower", "com.fournova.Tower3"), ("GitHub Desktop", "com.github.GitHubClient"),
                                  ("Terminal", "com.apple.Terminal"), ("iTerm", "com.googlecode.iterm2"), ("Warp", "dev.warp.Warp-Stable")]
    /// Terminals and git clients get a folder: Terminal would run a file as a script.
    private static let folderOnly: Set = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.DanPristupov.Fork",
                                          "com.fournova.Tower3", "com.github.GitHubClient"]

    static var installedEditors: [(name: String, bundle: String, app: URL)] {
        editors.compactMap { n, b in NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { (n, b, $0) } }
    }

    static func open(_ path: String, in bundle: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { NSSound.beep(); return }
        var p = path, dir: ObjCBool = false
        if folderOnly.contains(bundle), FileManager.default.fileExists(atPath: p, isDirectory: &dir), !dir.boolValue { p = (p as NSString).deletingLastPathComponent }
        NSWorkspace.shared.open([URL(fileURLWithPath: p)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// "Open in VS Code"… for whatever editors this Mac has, like "Open With" in Finder.
    static func addOpenIn(to menu: NSMenu, path: @escaping @MainActor () -> String?, prefix: String = String(localized: "Open in ")) {
        for e in installedEditors {
            let i = menu.add(prefix + e.name) {
                guard let p = path() else { NSSound.beep(); return }
                open(p, in: e.bundle)
            }
            i.image = NSWorkspace.shared.icon(forFile: e.app.path).resized(16)
        }
    }
    static func addOpenIn(to menu: NSMenu, path: String) { addOpenIn(to: menu, path: { path }) }

    /// The file in the focused tab, else the workspace's folder (Xcode's "Show in Finder" works on the selection).
    static func revealCurrent() {
        if let u = Workbench.editor?.focusedContent?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]); return }
        guard let w = AppModel.shared.worktree(Workbench.shared.workspaceId) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)])
    }

    static func delete(_ w: Worktree) {
        Task {
            let dirty = await AppModel.shared.call(WorktreeDirty(id: w.id)) ?? false
            let commits = await AppModel.shared.call(WorktreeUnmerged(id: w.id)) ?? 0
            let a = NSAlert(); a.messageText = String(localized: "Delete “\(w.displayName)” and its branch?")
            var lost: [String] = []
            if dirty { lost.append(String(localized: "It has uncommitted changes that will be lost.")) }
            if commits > 0 { lost.append(String(localized: "\(commits) commits on this branch aren't on any other branch or remote and will be lost.")) }
            a.informativeText = lost.isEmpty ? String(localized: "The checkout and branch \(w.branch) are removed. Running agents stop.") : lost.joined(separator: " ")
            a.addButton(withTitle: lost.isEmpty ? String(localized: "Delete Workspace and Branch") : String(localized: "Delete and Lose Changes")).hasDestructiveAction = true
            a.addButton(withTitle: String(localized: "Cancel")); a.alertStyle = lost.isEmpty ? .warning : .critical
            guard await runSheet(a) == .alertFirstButtonReturn, await UnsavedChanges.confirm(closing: [w.id]) else { return }
            if Workbench.shared.workspaceId == w.id, let main = AppModel.shared.worktrees.first(where: { $0.repoId == w.repoId && $0.id != w.id }) {
                Workbench.show(workspace: main.id)
            }
            await AppModel.shared.call(WorktreeRemove(id: w.id, force: dirty, dropCommits: commits > 0))
        }
    }

    /// The project's other git worktrees with nothing uncommitted (agents leave them in `.claude/worktrees`), after one
    /// question; git itself keeps any that changed meanwhile. Kelp's own workspaces aren't among them.
    static func removeCleanWorktrees(_ r: Repo) {
        Task {
            guard let all = await AppModel.shared.call(RepoWorktreeSizes(id: r.id)) else { return }
            let clean = all.filter(\.removable), a = NSAlert()
            guard !clean.isEmpty else {
                a.messageText = String(localized: "No clean worktrees in “\(r.name)”")
                a.informativeText = all.isEmpty ? String(localized: "The project has no other git worktrees.")
                    : String(localized: "Each of its \(all.count) worktrees has uncommitted changes, is locked or is a Kelp workspace.")
                _ = await runSheet(a); return
            }
            let size = WorktreeSizes.size(clean.reduce(0) { $0 + $1.bytes })
            a.messageText = clean.count == 1 ? String(localized: "Remove the clean worktree “\(WorktreeSizes.name(clean[0].path, root: r.path))” (\(size))?")
                : String(localized: "Remove \(clean.count) clean worktrees (\(size))?")
            let names = clean.prefix(10).map { "\(WorktreeSizes.name($0.path, root: r.path))  \(WorktreeSizes.size($0.bytes))" }
            a.informativeText = (clean.count > 1 ? names.joined(separator: "\n") + (clean.count > 10 ? "\n…" : "") + "\n\n" : "")
                + String(localized: """
                    Nothing uncommitted is lost: git removes only clean worktrees. A branch goes too if its commits are on another branch. \
                    Ignored files (builds, copied .env) go with the folder.
                    """)
            a.addButton(withTitle: clean.count == 1 ? String(localized: "Remove Worktree") : String(localized: "Remove \(clean.count) Worktrees")).hasDestructiveAction = true
            a.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(a) == .alertFirstButtonReturn,
                  let res = await AppModel.shared.call(RepoRemoveWorktrees(id: r.id, paths: clean.map(\.path))) else { return }
            let freed = WorktreeSizes.size(clean.filter { res.removed.contains($0.path) }.reduce(0) { $0 + $1.bytes })
            if let why = res.kept.values.first {
                Banner.show(String(localized: "Removed \(res.removed.count), kept \(res.kept.count): \(why)"), style: .error)
            } else { Banner.show(String(localized: "Removed \(res.removed.count) worktrees, \(freed) freed")) }
        }
    }

    /// A desk: its agents end, the folder stays. Asks only when agents are running there.
    static func close(_ w: Worktree) {
        // The project's last workspace stays (removing the project is a separate, deliberate action).
        guard AppModel.shared.worktrees.filter({ $0.repoId == w.repoId && !$0.archived }).count > 1 else { NSSound.beep(); return }
        let running = AppModel.shared.sessions.filter { $0.worktreeId == w.id && $0.status != .exited && $0.status != .hibernated }
        Task {
            if !running.isEmpty {
                let a = NSAlert(); a.messageText = String(localized: "Close “\(w.displayName)”?")
                a.informativeText = (running.count == 1 ? String(localized: "1 running agent stops. Files in the project are not touched.")
                    : String(localized: "\(running.count) running agents stop. Files in the project are not touched."))
                a.addButton(withTitle: running.count == 1 ? String(localized: "Stop Agent and Close")
                    : String(localized: "Stop \(running.count) Agents and Close")).hasDestructiveAction = true
                a.addButton(withTitle: String(localized: "Cancel"))
                guard await runSheet(a) == .alertFirstButtonReturn else { return }
            }
            guard await UnsavedChanges.confirm(closing: [w.id]) else { return }
            if Workbench.shared.workspaceId == w.id, let other = AppModel.shared.worktrees.first(where: { $0.repoId == w.repoId && $0.id != w.id }) {
                Workbench.show(workspace: other.id)
            }
            await AppModel.shared.call(WorktreeRemove(id: w.id))
            await AppModel.shared.refresh()
        }
    }

    /// The project's folder was moved or renamed: pick it again; its workspaces follow.
    static func relocate(_ r: Repo) {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = String(localized: "Where is “\(r.name)” now?"); p.prompt = String(localized: "Choose")
        p.directoryURL = URL(fileURLWithPath: (r.path as NSString).deletingLastPathComponent)
        let chosen = { (resp: NSApplication.ModalResponse) in
            guard resp == .OK, let u = p.url else { return }
            Task { if await AppModel.shared.call(RepoRelocate(id: r.id, path: u.path)) != nil { await AppModel.shared.refresh() } }
        }
        if let w = NSApp.mainWindow { p.beginSheetModal(for: w, completionHandler: chosen) } else { p.begin(completionHandler: chosen) }
    }

    /// Several at once (sidebar multi-selection): one question; each project keeps at least one workspace.
    /// Desks close; workspaces on their own branch are archived (nothing is deleted).
    static func close(_ ws: [Worktree]) {
        let m = AppModel.shared
        var closing: [Worktree] = []
        for (repo, picked) in Dictionary(grouping: ws, by: \.repoId) {
            let all = m.worktrees.filter { $0.repoId == repo && !$0.archived }
            closing += picked.count >= all.count ? Array(picked.sorted { $0.createdAt < $1.createdAt }.dropFirst()) : picked
        }
        guard !closing.isEmpty else { NSSound.beep(); return }
        let running = m.sessions.filter { s in closing.contains { $0.id == s.worktreeId } && s.status != .exited && s.status != .hibernated }
        let a = NSAlert(); a.messageText = closing.count == 1 ? String(localized: "Close 1 workspace?") : String(localized: "Close \(closing.count) workspaces?")
        a.informativeText = (running.isEmpty ? "" : running.count == 1 ? String(localized: "1 running session stops. ")
            : String(localized: "\(running.count) running sessions stop. "))
            + String(localized: "Files in the projects are not touched.") + (closing.count < ws.count ? " " + String(localized: "Each project keeps one workspace.") : "")
        let close = a.addButton(withTitle: running.isEmpty ? String(localized: "Close")
            : running.count == 1 ? String(localized: "Stop 1 Session and Close") : String(localized: "Stop \(running.count) Sessions and Close"))
        close.hasDestructiveAction = !running.isEmpty; a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn, await UnsavedChanges.confirm(closing: closing.map(\.id)) else { return }
            if closing.contains(where: { $0.id == Workbench.shared.workspaceId }),
               let other = m.worktrees.first(where: { w in !w.archived && !closing.contains { $0.id == w.id } }) { Workbench.show(workspace: other.id) }
            for w in closing {
                let desk = w.path == m.repo(w.repoId)?.path
                if desk { await m.call(WorktreeRemove(id: w.id)) } else { await m.call(WorktreeArchive(id: w.id)) }
            }
            await m.refresh()
        }
    }

    /// Out of the sidebar, nothing lost: its agents pause and its tabs stay until it comes back (Window › Archived Workspaces).
    static func archive(_ w: Worktree) {
        Task {
            guard await UnsavedChanges.confirm(closing: [w.id]) else { return }
            if Workbench.shared.workspaceId == w.id,
               let other = AppModel.shared.worktrees.first(where: { $0.repoId == w.repoId && $0.id != w.id && !$0.archived }) { Workbench.show(workspace: other.id) }
            if await AppModel.shared.call(WorktreeArchive(id: w.id)) != nil {
                await AppModel.shared.refresh()
                Banner.show(String(localized: "“\(w.displayName)” archived. Window › Archived Workspaces brings it back."))
            }
        }
    }

    static func unarchive(_ id: String) {
        Task {
            await AppModel.shared.call(WorktreeUnarchive(id: id))
            await AppModel.shared.refresh()
            Workbench.show(workspace: id)
        }
    }

    static func removeProject(_ r: Repo) {
        let a = NSAlert(); a.messageText = String(localized: "Remove “\(r.name)” from Kelp?"); a.informativeText = String(localized: "The repository on disk is not touched.")
        a.addButton(withTitle: String(localized: "Remove")); a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn,
                  await UnsavedChanges.confirm(closing: AppModel.shared.worktrees.filter { $0.repoId == r.id }.map(\.id)) else { return }
            await AppModel.shared.call(RepoRemove(id: r.id))
        }
    }
}

/// A file (or lines in it) handed to an agent or copied as a link.
@MainActor
enum FileActions {
    /// "Sources/App.swift:12-30": workspace-relative, the way agents read a reference.
    static func reference(_ path: String, lines: ClosedRange<Int>?) -> String {
        let root = AppModel.shared.worktree(Workbench.shared.workspaceId)?.path ?? ""
        let rel = !root.isEmpty && path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        let l = lines.map { $0.count == 1 ? ":\($0.lowerBound)" : ":\($0.lowerBound)-\($0.upperBound)" } ?? ""
        return IDE.escapedPath(rel) + l
    }

    /// The agent the user was last with in this workspace (never a plain terminal).
    static var targetAgent: Session? {
        let m = AppModel.shared, wid = Workbench.shared.workspaceId
        if let s = Workbench.shared.focusedSession.flatMap(m.session), s.agent != "shell", s.worktreeId == wid, s.status != .exited { return s }
        return m.sessions.last { $0.worktreeId == wid && $0.agent != "shell" && $0.status != .exited }
    }

    /// Types the reference into the agent's prompt without pressing Return, and shows the agent.
    static func sendToAgent(_ path: String, lines: ClosedRange<Int>? = nil) {
        guard let s = targetAgent else { Banner.show(String(localized: "No agent in this workspace. Start one with ⌥⌘T, then send again."), style: .error); return }
        Task { await AppModel.shared.call(SessionSend(id: s.id, text: reference(path, lines: lines) + " ", enter: false)) }
        Workbench.focus(session: s.id)
    }

    static func copyWebLink(_ path: String, lines: ClosedRange<Int>? = nil) {
        Task {
            guard let url = await AppModel.shared.call(GitWebURL(path: path, start: lines?.lowerBound, end: lines?.upperBound)) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
            Banner.show(String(localized: "Link copied"))
        }
    }

    static func copyReference(_ path: String, lines: ClosedRange<Int>?) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reference(path, lines: lines), forType: .string)
    }
}

/// A git step that failed for a reason an agent can fix (hooks, a rejected push, conflicts): the error banner
/// offers to hand it to the workspace's agent, with the error, as a prompt waiting for Return.
@MainActor
enum GitFix {
    static func offer(_ error: String, recipe: String, worktree wid: String, vars: [String: String] = [:]) {
        guard FileActions.targetAgent != nil else { Banner.show(error, style: .error); return }
        Banner.show(error, style: .error, action: (String(localized: "Ask Agent to Fix"), { send(recipe, worktree: wid, vars: vars.merging(["error": error]) { a, _ in a }) }))
    }

    static func send(_ recipe: String, worktree wid: String, vars: [String: String]) {
        guard let s = FileActions.targetAgent else { return }
        Task { if await type(recipe, worktree: wid, vars: vars, into: s.id) { Workbench.focus(session: s.id) } }
    }

    /// The recipe typed into the session, not sent: other people's text (errors, CI logs, review comments) waits for Return.
    static func type(_ recipe: String, worktree wid: String, vars: [String: String], into sid: String) async -> Bool {
        guard let text = await AppModel.shared.call(RecipeRender(id: wid, name: recipe, vars: vars)) else { return false }
        await AppModel.shared.call(SessionSend(id: sid, text: text, enter: false))
        return true
    }
}

@MainActor
enum PRActions {
    /// Pushes and opens a PR; title and body come from the branch's commits.
    static func create(worktree wid: String) {
        let a = NSAlert(); a.messageText = String(localized: "Create a pull request?")
        a.informativeText = String(localized: "Pushes \(AppModel.shared.worktree(wid)?.branch ?? "the branch") and opens a PR titled from its commits.")
        a.addButton(withTitle: String(localized: "Create")); a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            guard let url = await AppModel.shared.call(GitHubPRCreate(worktreeId: wid))?.url else { return }
            Banner.show(url.isEmpty ? String(localized: "Pull request created") : String(localized: "Pull request created: \(url)"))
            if let u = URL(string: url), !url.isEmpty { Workbench.open(u.absoluteString) }
        }
    }
}
