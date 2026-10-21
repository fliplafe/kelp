import AppKit
import Core
import GitKit

/// What the sidebar shows beside a folder: lines not committed yet and the branch's PR. Desks share their project's
/// folder, so the project row carries it; a workspace on its own branch (a worktree) carries its own.
/// Read once a minute for folders on screen, and when Source Control sees a change.
@MainActor
@Observable
final class RowBadges {
    static let shared = RowBadges()
    private(set) var stats: [String: LineStats] = [:]   // worktree id → changes
    private(set) var prs: [String: JSONValue] = [:]     // worktree id → its branch's PR
    @ObservationIgnored private var asked: [String: Date] = [:]

    private init() {
        NotificationCenter.default.addObserver(forName: .kelpGitChanged, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if let id = n.object as? String { RowBadges.shared.refresh(id, force: true) } }
        }
    }

    /// The worktree whose folder a row stands for (nil: the row has none of its own).
    static func folder(project id: String) -> Worktree? {
        let m = AppModel.shared
        guard let r = m.repo(id) else { return nil }
        return m.worktrees.first { $0.repoId == id && $0.path == r.path && !$0.archived }
    }
    static func folder(workspace id: String) -> Worktree? {
        let m = AppModel.shared
        guard let w = m.worktree(id), w.path != m.repo(w.repoId)?.path else { return nil }
        return w
    }

    func refresh(_ wid: String, force: Bool = false) {
        guard force || Date().timeIntervalSince(asked[wid] ?? .distantPast) > 60, let c = AppModel.shared.client else { return }
        asked[wid] = Date()
        Task {
            let s = try? await c.call("git.lineStats", .obj(["id": .string(wid)]), as: LineStats.self)
            if s != stats[wid] { stats[wid] = s }
            let p = try? await c.call("github.branchPR", .obj(["worktreeId": .string(wid)]))
            let pr = p?["number"] != nil ? p : nil
            if pr != prs[wid] { prs[wid] = pr }
        }
    }

    /// "+6 −2" in green and red (text shades: NSColor.textGreen); a side with nothing changed is left out ("+6", not "+6 −0").
    static func changes(_ s: LineStats?) -> NSAttributedString? {
        guard let s, s.totalAdded + s.totalRemoved > 0 else { return nil }
        return changes(added: s.totalAdded, removed: s.totalRemoved)
    }
    static func changes(added: Int, removed: Int, font: NSFont = .uiDigits(11, weight: .regular)) -> NSAttributedString {
        let t = NSMutableAttributedString()
        for (text, n, color) in [("+\(added)", added, NSColor.textGreen), ("−\(removed)", removed, NSColor.textRed)] where n > 0 {
            t.append(NSAttributedString(string: (t.length > 0 ? " " : "") + text, attributes: [.font: font, .foregroundColor: color]))
        }
        return t
    }

    /// "#12" in the PR's state colour, with a mark for its checks.
    static func pr(_ p: JSONValue?) -> (NSAttributedString, String)? {
        guard let p, let n = p["number"]?.int else { return nil }
        let state = p["isDraft"]?.bool == true ? "DRAFT" : p["state"]?.string ?? ""
        let color: NSColor = state == "DRAFT" ? .secondaryLabelColor : state == "MERGED" ? .textPurple : state == "CLOSED" ? .textRed : .textGreen
        let failed = p["checks"]?["failed"]?.int ?? 0, pending = p["checks"]?["pending"]?.int ?? 0, passed = p["checks"]?["passed"]?.int ?? 0
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
        return (t, String(localized: "Pull request #\(n) · \(said) · \(checks)") + "\n" + (p["title"]?.string ?? ""))
    }
}
