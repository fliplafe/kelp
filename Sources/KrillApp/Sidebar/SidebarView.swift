import SwiftUI
import Core

/// Projects → workspaces → agents, with live agent status. "+" on a project makes a workspace instantly.
struct SidebarView: View {
    private var model = AppModel.shared
    private var bench = Workbench.shared
    @State private var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sidebar.collapsed") ?? [])
    @State private var renaming: String?
    @State private var name = ""
    @State private var creating: String?

    private var selection: Binding<String?> {
        Binding(get: { bench.workspaceId.map { "w:" + $0 } },
                set: { tag in
                    guard let tag else { return }
                    let id = String(tag.dropFirst(2))
                    if tag.hasPrefix("w:") { Workbench.show(workspace: id) } else { Workbench.focus(session: id) }
                })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(model.repos) { repo in
                Section {
                    ForEach(model.workspaces(of: repo)) { w in workspace(w, repo: repo) }
                } header: {
                    ProjectHeader(repo: repo, creating: creating == repo.id) { newWorkspace(repo) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
        .overlay {
            if model.repos.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder.badge.plus")
                } description: { Text("Add a git repository to start.") } actions: {
                    Button("Add Project…") { Workbench.addProject() }
                }
            }
        }
    }

    @ViewBuilder
    private func workspace(_ w: Worktree, repo: Repo) -> some View {
        let agents = model.sessions.filter { $0.worktreeId == w.id && $0.status != .exited }
        let open = !collapsed.contains(w.id)
        WorkspaceRow(workspace: w, isMain: w.path == repo.path, agents: agents, expanded: open, renaming: renaming == w.id, name: $name,
                     toggle: { toggle(w.id) }, commitRename: { commitRename(w) })
            .tag("w:" + w.id)
            .contextMenu { workspaceMenu(w, repo: repo) }
        if open {
            ForEach(agents) { s in
                AgentRow(session: s)
                    .tag("a:" + s.id)
                    .padding(.leading, 18)
                    .contextMenu { agentMenu(s) }
            }
        }
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        UserDefaults.standard.set(Array(collapsed), forKey: "sidebar.collapsed")
    }

    private func newWorkspace(_ repo: Repo) {
        creating = repo.id
        Task {
            if let w = await AppModel.shared.call("worktree.create", .obj(["repoId": .string(repo.id)])), let id = w["id"]?.string {
                await AppModel.shared.refresh()
                Workbench.show(workspace: id)
            }
            creating = nil
        }
    }

    private func commitRename(_ w: Worktree) {
        let n = name.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !n.isEmpty, n != w.displayName else { return }
        Task { await AppModel.shared.call("worktree.note", .obj(["id": .string(w.id), "note": .string(n)])) }
    }

    @ViewBuilder
    private func workspaceMenu(_ w: Worktree, repo: Repo) -> some View {
        Menu("New Agent") {
            ForEach(AgentCatalog.installed(AgentCatalog.all)) { a in
                Button(a.name) { Workbench.show(workspace: w.id); Workbench.editor?.newAgent(a.id) }
            }
        }
        Button("New Terminal") { Workbench.show(workspace: w.id); Workbench.editor?.newTerminal() }
        Divider()
        Button("Rename…") { name = w.displayName; renaming = w.id }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(w.path, forType: .string) }
        if w.path != repo.path {
            Divider()
            Button("Archive") { Task { await AppModel.shared.call("worktree.archive", .obj(["id": .string(w.id)])) } }
            Button("Delete Workspace & Branch…", role: .destructive) { WorkspaceActions.delete(w) }
        }
    }

    @ViewBuilder
    private func agentMenu(_ s: Session) -> some View {
        Button("Show") { Workbench.focus(session: s.id) }
        Button("Rename…") { AgentActions.rename(s.id) }
        Button("Restart") { AgentActions.restart(s.id) }
        Divider()
        Button("Fork to New Workspace…") { AgentActions.fork(s.id) }
        Button("Hand Off to Another Agent…") { AgentActions.handoff(s.id) }
        Button("Copy Context") { AgentActions.copyContext(s.id) }
        Divider()
        Button("Stop", role: .destructive) { Task { await AppModel.shared.call("session.kill", .obj(["id": .string(s.id)])) } }
    }
}

private struct ProjectHeader: View {
    let repo: Repo
    let creating: Bool
    let add: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(repo.name).help(repo.path)
            Spacer()
            if creating { ProgressView().controlSize(.mini) } else {
                Button(action: add) { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New workspace in \(repo.name) (⌘N)")
            }
        }
        .contextMenu {
            Button("New Workspace", action: add)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)]) }
            Divider()
            Button("Remove Project…", role: .destructive) { WorkspaceActions.removeProject(repo) }
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: Worktree
    let isMain: Bool
    let agents: [Session]
    let expanded: Bool
    let renaming: Bool
    @Binding var name: String
    let toggle: () -> Void
    let commitRename: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.tertiary).frame(width: 10)
            }
            .buttonStyle(.plain).opacity(agents.isEmpty ? 0 : 1).disabled(agents.isEmpty)
            Image(systemName: isMain ? "house" : "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Name", text: $name).textFieldStyle(.plain).focused($focused)
                        .onSubmit(commitRename).onAppear { focused = true }
                        .onExitCommand { commitRename() }
                } else {
                    Text(workspace.displayName).fontWeight(agents.contains(where: \.unread) ? .semibold : .regular).lineLimit(1)
                }
                if workspace.displayName != workspace.branch {
                    Text(workspace.branch).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            WorkspaceBadge(agents: agents)
        }
        .help(workspace.path)
    }
}

/// The most urgent state among a workspace's agents, with a count when several need you.
private struct WorkspaceBadge: View {
    let agents: [Session]
    var body: some View {
        let ai = agents.filter { $0.agent != "shell" }
        let waiting = ai.filter { $0.status == .waiting }.count
        HStack(spacing: 4) {
            if waiting > 0 {
                Label("\(waiting)", systemImage: "questionmark.circle.fill").labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange).help("\(waiting) waiting for you")
            } else if ai.contains(where: { $0.status == .working }) {
                ProgressView().controlSize(.mini).help("Working")
            } else if ai.contains(where: { $0.status == .done && $0.unread }) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Done")
            }
        }
    }
}

private struct AgentRow: View {
    let session: Session
    var body: some View {
        HStack(spacing: 7) {
            if session.agent == "shell" { Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 14) } else {
                StatusIcon(status: session.status).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title.isEmpty ? AgentCatalog.name(session.agent) : session.title)
                    .fontWeight(session.unread ? .semibold : .regular).lineLimit(1)
                if session.agent != "shell" {
                    Text(session.summary.isEmpty || session.status == .waiting ? session.status.words : session.summary)
                        .font(.caption).foregroundStyle(session.status == .waiting ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)).lineLimit(1)
                }
            }
        }
        .help("\(AgentCatalog.name(session.agent)) · \(session.status.words)" + (session.summary.isEmpty ? "" : "\n\(session.summary)"))
    }
}

/// Bottom of the sidebar: agent limits, then "Add Project".
private struct SidebarFooter: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            UsageView().padding(.horizontal, 12).padding(.top, 8)
            HStack {
                Button { Workbench.addProject() } label: { Label("Add Project", systemImage: "plus") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}
