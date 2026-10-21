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
}
