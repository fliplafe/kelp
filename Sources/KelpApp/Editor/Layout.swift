import Foundation
import WorkbenchKit

/// Each workspace's layout is kept in UserDefaults so a relaunch shows the same arrangement.
extension WorkspaceLayout {
    static func load(_ workspace: String) -> WorkspaceLayout {
        guard let d = UserDefaults.standard.data(forKey: "layout3.\(workspace)"), let l = try? JSONDecoder().decode(WorkspaceLayout.self, from: d) else { return WorkspaceLayout() }
        return l
    }
    func save(_ workspace: String) { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "layout3.\(workspace)") }
}
