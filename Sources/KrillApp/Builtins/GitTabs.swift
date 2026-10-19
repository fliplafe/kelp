import AppKit
import Core

/// "diff:<workspace>" (every change) or "diff:<workspace>?file=<path>[&source=unstaged|staged][&commit=<hash>]" (one file,
/// like VS Code's diff editor: "name (Working Tree)", "name (Index)", "name (abc1234)").
@MainActor
final class DiffTab: TabContent {
    let worktreeId: String
    private let controller = DiffViewController()
    private let file: String?, source: String?, commit: String?
    var onChange: (() -> Void)?
    private(set) var uri: String
    var view: NSView { controller.view }
    var title: String {
        guard let file else { return "Changes" }
        let what = commit.map { String($0.prefix(7)) } ?? (source == "staged" ? "Index" : "Working Tree")
        return "\((file as NSString).lastPathComponent) (\(what))"
    }
    var icon: NSImage? { .symbol("plusminus") }
    var toolTip: String? { file }

    init(uri: String) {
        self.uri = uri
        let parts = TabURI.body(uri).split(separator: "?", maxSplits: 1)
        worktreeId = parts.first.map(String.init) ?? ""
        let q = parts.count > 1 ? URLComponents(string: "x:?" + parts[1])?.queryItems ?? [] : []
        func item(_ n: String) -> String? { q.first { $0.name == n }?.value }
        file = item("file"); source = item("source"); commit = item("commit")
        controller.currentSession = { Workbench.shared.focusedSession }
        _ = controller.view
        if let file { controller.showFile(file, source: source ?? "unstaged", commit: commit) }
        controller.show(worktree: worktreeId)
        NotificationCenter.default.addObserver(forName: .krillGitChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if (n.object as? String) == self?.worktreeId, self?.commit == nil { self?.controller.reload() } }
        }
    }

    func focus() { controller.view.window?.makeFirstResponder(controller.view) }

    static func uri(_ worktree: String, file: String? = nil, source: String? = nil, commit: String? = nil) -> String {
        var c = URLComponents()
        c.queryItems = [("file", file), ("source", source), ("commit", commit)].compactMap { n, v in v.map { URLQueryItem(name: n, value: $0) } }
        return "diff:\(worktree)" + (c.queryItems?.isEmpty == false ? "?" + (c.percentEncodedQuery ?? "") : "")
    }
}

extension Notification.Name { static let krillGitChanged = Notification.Name("krill.git.changed") }
