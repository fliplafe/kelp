import Foundation
import Observation

/// What's on screen: the selected workspace and what has focus in it.
@MainActor
@Observable
final class Workbench {
    static let shared = Workbench()
    var workspaceId: String? { didSet { if workspaceId != oldValue { UserDefaults.standard.set(workspaceId, forKey: "lastWorkspace") } } }
    var focusedSession: String?
    var focusedFile: String?
    var inspectorPanel: String = UserDefaults.standard.string(forKey: "inspectorPanel") ?? "git.changes" {
        didSet { UserDefaults.standard.set(inspectorPanel, forKey: "inspectorPanel") }
    }
}
