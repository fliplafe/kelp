import Foundation
import Observation
import Core

/// What's on screen: the selected workspace and what has focus in it.
@MainActor
@Observable
final class Workbench {
    static let shared = Workbench()
    var workspaceId: String? { didSet { UIState["workbench.lastWorkspace"] = workspaceId.map(JSONValue.string) } }
    var focusedSession: String?
    var focusedFile: String?
    var inspectorPanel: String = ProcessInfo.processInfo.environment["KELP_SNAPSHOT_INSPECTOR"]
        ?? UserDefaults.standard.string(forKey: "inspectorPanel") ?? "git.changes" {
        didSet { UserDefaults.standard.set(inspectorPanel, forKey: "inspectorPanel") }
    }
    /// Workspaces in the order they were shown, for Back / Forward (⌃⌘← / ⌃⌘→), like a browser's history.
    /// Observed: the title bar's arrows follow it.
    var visits: [String] = []
    var visitAt = -1
}
