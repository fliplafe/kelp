import AppKit
import Core

/// By Add Project in the title bar: the workspace's folder in the app this project was last opened in (VS Code, Cursor,
/// Fork…); the arrow lists the others this Mac has. File › Open Workspace In is the same list.
@MainActor
final class OpenInButton: NSComboButton {
    private var bundle: String?

    convenience init() {
        self.init(image: .symbol("arrow.up.forward.app", String(localized: "Open In")), menu: NSMenu(), target: nil, action: nil)
        target = self; action = #selector(openChosen)
        style = .split; imageScaling = .scaleProportionallyDown; controlSize = .small
        track { "\(Workbench.shared.workspaceId ?? "")|\(AppModel.shared.worktrees.count)" } changed: { [weak self] _ in self?.update() }
    }

    private var worktree: Worktree? { AppModel.shared.worktree(Workbench.shared.workspaceId) }
    private static func key(_ w: Worktree) -> String { "openIn." + w.repoId }

    private func update() {
        let apps = WorkspaceActions.installedEditors
        guard let w = worktree, !apps.isEmpty else { isHidden = true; return }
        isHidden = false
        let saved = UserDefaults.standard.string(forKey: Self.key(w))
        let pick = apps.first { $0.bundle == saved } ?? apps[0]
        bundle = pick.bundle
        // The button keeps its monochrome symbol: an app's colour icon would be the loudest thing in the chrome.
        // The menu shows the apps' own icons, as Finder's Open With does.
        toolTip = String(localized: "Open \(w.displayName) in \(pick.name)")
        let m = NSMenu()
        for a in apps {
            let i = m.add(a.name) { [weak self] in
                UserDefaults.standard.set(a.bundle, forKey: Self.key(w)); self?.update(); self?.openChosen()
            }
            i.image = NSWorkspace.shared.icon(forFile: a.app.path).resized(16)
            i.state = a.bundle == pick.bundle ? .on : .off
        }
        menu = m
    }

    @objc private func openChosen() {
        guard let w = worktree, let bundle else { NSSound.beep(); return }
        WorkspaceActions.open(w.path, in: bundle)
    }
}
