import Foundation
import Core
import WorkbenchKit

/// Each workspace's layout is kept in the daemon's database (`layout/<id>`, see `UIState`) so a relaunch shows the same arrangement.
extension WorkspaceLayout {
    @MainActor static func load(_ workspace: String) -> WorkspaceLayout {
        (try? UIState["layout/\(workspace)"]?.decode(WorkspaceLayout.self)) ?? WorkspaceLayout()
    }
    @MainActor func save(_ workspace: String) { UIState["layout/\(workspace)"] = try? .from(self) }
}
