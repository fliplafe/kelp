import AppKit
import Core

/// "diff:<workspace>" (whole review) or "diff:<workspace>?file=<relative path>".
@MainActor
final class DiffTab: TabContent {
    let worktreeId: String
    private let controller = DiffViewController()
    var onChange: (() -> Void)?
    private(set) var uri: String
    var view: NSView { controller.view }
    var title: String { "Changes" }
    var icon: NSImage? { .symbol("plusminus") }

    init(uri: String) {
        self.uri = uri
        let body = TabURI.body(uri)
        let parts = body.split(separator: "?", maxSplits: 1)
        worktreeId = parts.first.map(String.init) ?? ""
        controller.currentSession = { Workbench.shared.focusedSession }
        _ = controller.view
        controller.show(worktree: worktreeId)
        if parts.count > 1, let f = URLComponents(string: "x:?" + parts[1])?.queryItems?.first(where: { $0.name == "file" })?.value { controller.focus(file: f) }
        NotificationCenter.default.addObserver(forName: .krillGitChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if (n.object as? String) == self?.worktreeId { self?.controller.reload() } }
        }
    }

    func show(file: String) { controller.focus(file: file) }
    func focus() { controller.view.window?.makeFirstResponder(controller.view) }

    static func uri(_ worktree: String, file: String? = nil) -> String {
        "diff:\(worktree)" + (file.map { "?file=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) } ?? "")
    }
}

extension Notification.Name { static let krillGitChanged = Notification.Name("krill.git.changed") }
