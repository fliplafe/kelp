import AppKit
import Core

/// What the sidebar shows beside a folder: lines not committed yet and the branch's PR. Desks share their project's
/// folder, so the project row carries it; a workspace on its own branch (a worktree) carries its own. Every folder the
/// sidebar lists is watched: the daemon pushes its git when its files change, and its PR (gh, once a minute).
@MainActor
package final class RowBadges {
    private let app: AppModel
    /// Worktree id → changes / its branch's PR (observed through AppModel).
    var stats: [String: LineStats] { app.git.compactMapValues(\.stats) }
    var prs: [String: GitHub.PullRequest] { app.prs }
    private var folders = Set<String>()

    package init(app: AppModel) {
        self.app = app
        track(owner: self) { [weak self] in
            guard let self else { return Set<String>() }
            return Set(app.repos.compactMap { self.folder(project: $0.id)?.id } + app.worktrees.compactMap { self.folder(workspace: $0.id)?.id })
        } changed: { [weak self] in self?.follow($0) }
    }

    private func follow(_ now: Set<String>) {
        let m = app
        for id in now.subtracting(folders) { m.watch(.git, id); m.watch(.pr, id) }
        for id in folders.subtracting(now) { m.unwatch(.git, id); m.unwatch(.pr, id) }
        folders = now
    }

    /// The worktree whose folder a row stands for (nil: the row has none of its own).
    func folder(project id: String) -> Worktree? {
        let m = app
        guard let r = m.repo(id) else { return nil }
        return m.worktrees.first { $0.repoId == id && $0.path == r.path && !$0.archived }
    }
    func folder(workspace id: String) -> Worktree? {
        let m = app
        guard let w = m.worktree(id), !w.archived, w.path != m.repo(w.repoId)?.path else { return nil }
        return w
    }

    /// "+6 −2" in green and red (text shades: NSColor.textGreen); a side with nothing changed is left out ("+6", not "+6 −0").
    package static func changes(_ s: LineStats?) -> NSAttributedString? {
        guard let s, s.totalAdded + s.totalRemoved > 0 else { return nil }
        return changes(added: s.totalAdded, removed: s.totalRemoved)
    }
    package static func changes(added: Int, removed: Int) -> NSAttributedString {
        let t = NSMutableAttributedString(), font = NSFont.uiDigits(11, weight: .regular)
        for (text, n, color) in [("+\(added)", added, NSColor.textGreen), ("−\(removed)", removed, NSColor.textRed)] where n > 0 {
            t.append(NSAttributedString(string: (t.length > 0 ? " " : "") + text, attributes: [.font: font, .foregroundColor: color]))
        }
        return t
    }

    /// "#12" in the PR's state colour, with a mark for its checks.
    static func pr(_ p: GitHub.PullRequest?) -> (NSAttributedString, String)? {
        guard let p else { return nil }
        let n = p.number, state = p.isDraft ? "DRAFT" : p.state
        let color: NSColor = state == "DRAFT" ? .secondaryLabelColor : state == "MERGED" ? .textPurple : state == "CLOSED" ? .textRed : .textGreen
        let failed = p.checks.failed, pending = p.checks.pending, passed = p.checks.passed
        let f = NSFont.uiDigits(11, weight: .medium)
        let t = NSMutableAttributedString(string: "#\(n)", attributes: [.font: f, .foregroundColor: color])
        let (mark, mc): (String, NSColor) = failed > 0 ? (" ✕", .textRed) : pending > 0 ? (" ●", .textOrange) : passed > 0 ? (" ✓", .textGreen) : ("", color)
        if !mark.isEmpty { t.append(NSAttributedString(string: mark, attributes: [.font: NSFont.ui(9, weight: .bold), .foregroundColor: mc])) }
        let checks = failed > 0 ? String(localized: "\(failed) checks failing") : pending > 0 ? String(localized: "\(pending) checks running")
            : passed > 0 ? String(localized: "checks passed") : String(localized: "no checks")
        let said = switch state {
        case "DRAFT": String(localized: "draft")
        case "MERGED": String(localized: "merged")
        case "CLOSED": String(localized: "closed")
        default: String(localized: "open")
        }
        return (t, String(localized: "Pull request #\(n) · \(said) · \(checks)") + "\n" + p.title)
    }
}
