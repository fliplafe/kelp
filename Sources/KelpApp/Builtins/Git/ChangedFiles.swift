import Foundation
import Core
import GitKit

/// The number on the Source Control icon: files changed in the workspace on screen. It watches the folder itself, since
/// the panel is only built once it's shown; the open panel reports what it read so the two agree.
@MainActor
@Observable
final class ChangedFiles {
    static let shared = ChangedFiles()
    private(set) var count = 0
    @ObservationIgnored private var wid: String?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private let pending = Debounce()
    /// The Source Control panel, once built: while it shows this workspace its own reloads report the count.
    @ObservationIgnored weak var panel: SourceControlController?

    private init() {
        // The path too: on launch the workspace is known before the daemon has listed its folder.
        track { [Workbench.shared.workspaceId, AppModel.shared.worktree(Workbench.shared.workspaceId)?.path] } changed: { [weak self] in
            self?.bind($0[0], path: $0[1])
        }
    }

    private func bind(_ id: String?, path: String?) {
        wid = id; count = 0
        watcher = path.flatMap { FileWatcher(root: $0) { [weak self] in if Git.touchesStatus($0) { self?.scheduleReload() } } }
        reload()
    }

    private func scheduleReload() { pending.after(0.4) { [weak self] in self?.reload() } }

    private func reload() {
        guard let wid, panel?.workspace != wid, let c = AppModel.shared.client else { return }
        Task {
            let ch = try? await c.call("git.status", .obj(["id": .string(wid)]), as: [FileChange].self)
            report(wid, ch?.count ?? 0)
        }
    }

    /// Source Control read the status already.
    func report(_ id: String, _ n: Int) { if id == wid, n != count { count = n } }
}
