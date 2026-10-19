import SwiftUI
import Core
import GitKit

/// Git for the workspace on screen: branch, changed files (click → diff tab), stage / unstage / discard, commit, push, PR.
@MainActor
@Observable
final class ChangesModel {
    var changes: [FileChange] = []
    var branch = ""
    var message = ""
    var busy = false
    var generating = false
    private(set) var worktreeId: String?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var pending: DispatchWorkItem?

    func bind(_ wid: String?) {
        guard wid != worktreeId else { return }
        worktreeId = wid; changes = []; message = ""
        watcher = AppModel.shared.worktree(wid).flatMap { w in FileWatcher(root: w.path) { [weak self] _ in self?.scheduleReload() } }
        Task { await reload() }
    }
    private func scheduleReload() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { await self?.reload() } }
        pending = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
    func reload() async {
        guard let wid = worktreeId, let c = AppModel.shared.client else { return }
        changes = (try? await c.call("git.status", .obj(["id": .string(wid)]), as: [FileChange].self)) ?? []
        branch = AppModel.shared.worktree(wid)?.branch ?? ""
        NotificationCenter.default.post(name: .krillGitChanged, object: wid)
    }
    var staged: [FileChange] { changes.filter(\.staged) }
    var unstaged: [FileChange] { changes.filter { $0.unstaged || $0.untracked } }

    func stage(_ files: [String], _ on: Bool) {
        guard let wid = worktreeId else { return }
        Task { await AppModel.shared.call(on ? "git.stage" : "git.unstage", .obj(["id": .string(wid), "files": .array(files.map { .string($0) })])); await reload() }
    }
    func discard(_ f: FileChange) {
        guard let w = AppModel.shared.worktree(worktreeId) else { return }
        let a = NSAlert(); a.messageText = "Discard changes to \((f.path as NSString).lastPathComponent)?"; a.informativeText = "This can't be undone."
        a.addButton(withTitle: "Discard"); a.addButton(withTitle: "Cancel"); a.alertStyle = .warning
        guard runAsSheet(a) == .alertFirstButtonReturn else { return }
        let args = f.untracked ? ["clean", "-f", "--", f.path] : ["checkout", "HEAD", "--", f.path]
        _ = try? Git.run(args, cwd: w.path)
        Task { await reload() }
    }
    func generate() {
        guard let wid = worktreeId, let c = AppModel.shared.client else { return }
        generating = true
        Task {
            message = (try? await c.call("ai.commitMessage", .obj(["id": .string(wid)])))?.string ?? message
            generating = false
        }
    }
    func commit(push: Bool) {
        guard let wid = worktreeId, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        Task {
            let ok = await AppModel.shared.call("git.commit", .obj(["id": .string(wid), "message": .string(message), "all": .bool(staged.isEmpty)])) != nil
            if ok { message = "" }
            if ok, push { await AppModel.shared.call("git.push", .obj(["id": .string(wid)])) }
            busy = false; await reload()
        }
    }
    func push() { guard let wid = worktreeId else { return }; busy = true; Task { await AppModel.shared.call("git.push", .obj(["id": .string(wid)])); busy = false } }
    func createPR() { if let wid = worktreeId { PRActions.create(worktree: wid) } }
}

struct ChangesPanel: View {
    @State private var model = ChangesModel()
    private var bench = Workbench.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text(model.branch).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh")
                Menu {
                    Button("Push") { model.push() }
                    Button("Create Pull Request…") { model.createPR() }
                    Divider()
                    Button("Open Full Review") { if let w = model.worktreeId { Workbench.open(DiffTab.uri(w)) } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("More")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if model.changes.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("Edits in this workspace show up here."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    if !model.staged.isEmpty {
                        Section("Staged") { ForEach(model.staged, id: \.path) { row($0, staged: true) } }
                    }
                    Section("Changes") { ForEach(model.unstaged, id: \.path) { row($0, staged: false) } }
                }
                .listStyle(.sidebar)
            }
            Divider()
            commitBox
        }
        .onAppear { model.bind(bench.workspaceId) }
        .onChange(of: bench.workspaceId) { _, w in model.bind(w) }
    }

    private func row(_ f: FileChange, staged: Bool) -> some View {
        let (letter, color) = Self.badge(f, staged: staged)
        return HStack(spacing: 6) {
            Text(letter).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(color).frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text((f.path as NSString).lastPathComponent).lineLimit(1)
                let dir = (f.path as NSString).deletingLastPathComponent
                if !dir.isEmpty { Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            Spacer(minLength: 4)
            HoverButtons(staged: staged, onStage: { model.stage([f.path], !staged) }, onDiscard: staged ? nil : { model.discard(f) })
        }
        .contentShape(Rectangle())
        .onTapGesture { if let w = model.worktreeId { Workbench.open(DiffTab.uri(w, file: f.path)) } }
        .contextMenu {
            Button(staged ? "Unstage" : "Stage") { model.stage([f.path], !staged) }
            if let w = AppModel.shared.worktree(model.worktreeId) {
                Button("Open File") { Workbench.open(TabURI.file(w.path + "/" + f.path)) }
            }
            if !staged { Button("Discard Changes…", role: .destructive) { model.discard(f) } }
        }
    }

    static func badge(_ f: FileChange, staged: Bool) -> (String, Color) {
        if f.untracked { return ("U", .green) }
        if f.conflicted { return ("!", .red) }
        switch staged ? f.index : f.worktree {
        case "A": return ("A", .green)
        case "D": return ("D", .red)
        case "R": return ("R", .blue)
        default: return ("M", .orange)
        }
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Commit message", text: $model.message, axis: .vertical)
                .lineLimit(2...6).textFieldStyle(.roundedBorder)
            HStack {
                Button { model.generate() } label: {
                    if model.generating { ProgressView().controlSize(.small) } else { Label("Generate", systemImage: "sparkles") }
                }
                .help("Draft from the diff with the on-device model").disabled(model.changes.isEmpty)
                Spacer()
                Menu("Commit") {
                    Button("Commit & Push") { model.commit(push: true) }
                } primaryAction: { model.commit(push: false) }
                .fixedSize()
                .disabled(model.busy || model.message.trimmingCharacters(in: .whitespaces).isEmpty || model.changes.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            if !model.changes.isEmpty, model.staged.isEmpty {
                Text("Nothing staged: Commit takes all changes.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

/// Stage / discard buttons that appear on hover, like Xcode's source control navigator.
private struct HoverButtons: View {
    let staged: Bool
    let onStage: () -> Void
    let onDiscard: (() -> Void)?
    @State private var hover = false
    var body: some View {
        HStack(spacing: 2) {
            if let onDiscard { Button(action: onDiscard) { Image(systemName: "arrow.uturn.backward") }.help("Discard Changes") }
            Button(action: onStage) { Image(systemName: staged ? "minus" : "plus") }.help(staged ? "Unstage" : "Stage")
        }
        .buttonStyle(.borderless).foregroundStyle(hover ? .primary : .tertiary)
        .onHover { hover = $0 }
    }
}
