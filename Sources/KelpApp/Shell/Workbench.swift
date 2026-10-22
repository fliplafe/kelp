import Foundation
import Observation
import Core
import WorkbenchKit

/// What's on screen: the selected workspace and what has focus in it.
@MainActor
@Observable
final class Workbench {
    static let shared = Workbench()
    var workspaceId: String? { didSet { UIState["workbench.lastWorkspace"] = workspaceId.map(JSONValue.string) } }
    var focusedSession: String?
    /// The tab with focus in the workspace on screen (its URI): the sidebar marks its agent's row.
    var focusedTab: String?
    var focusedFile: String?
    /// The workspace on screen puts its agents side by side as they open (the title bar's button, ⌃⌘T).
    var sideBySide = true
    var inspectorPanel: String = UserDefaults.standard.string(forKey: "inspectorPanel") ?? "git.changes" {
        didSet { UserDefaults.standard.set(inspectorPanel, forKey: "inspectorPanel") }
    }
    /// For Back / Forward (⌃⌘← / ⌃⌘→). Observed: the title bar's arrows follow it.
    var history = WorkspaceHistory()
    /// Columns × rows of the last terminal seen on screen: sizes the next one before it's shown. Kept across launches:
    /// the window usually opens at the same size.
    static var terminalGrid: (cols: Int, rows: Int)? = {
        let g = UserDefaults.standard.array(forKey: "terminal.lastGrid") as? [Int] ?? []
        return g.count == 2 ? (g[0], g[1]) : nil
    }() {
        didSet { if let g = terminalGrid, g != oldValue ?? (0, 0) { UserDefaults.standard.set([g.cols, g.rows], forKey: "terminal.lastGrid") } }
    }
}
