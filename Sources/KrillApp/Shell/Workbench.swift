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
    var inspectorPanel: String = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_INSPECTOR"]
        ?? UserDefaults.standard.string(forKey: "inspectorPanel") ?? "git.changes" {
        didSet { UserDefaults.standard.set(inspectorPanel, forKey: "inspectorPanel") }
    }
    /// Workspaces in the order they were shown, for Back / Forward (⌃⌘← / ⌃⌘→), like a browser's history.
    @ObservationIgnored var visits: [String] = []
    @ObservationIgnored var visitAt = -1
}
