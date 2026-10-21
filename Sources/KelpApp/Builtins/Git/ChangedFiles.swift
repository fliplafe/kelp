import Foundation
import Core

/// The workspace on screen's git, watched for as long as it's on screen (the daemon pushes it when its files change):
/// the number on the Source Control icon, the window bar's branch chip and Source Control itself read `AppModel.git`.
@MainActor
final class ChangedFiles {
    static let shared = ChangedFiles()
    private let watched = Watched(.git)

    /// Files changed in the workspace on screen.
    var count: Int { AppModel.shared.git[Workbench.shared.workspaceId ?? ""]?.changes?.count ?? 0 }

    private init() {
        track { Workbench.shared.workspaceId } changed: { [weak self] in self?.watched.key = $0 }
    }
}
