import AppKit
import SwiftUI
import Core
import Agents
import WorkbenchKit
import KelpKit

extension Builtins {

    package static let git = Builtin("kelp.git", "Git", "Source Control: changes and staging, commits, branches, the history graph and diffs.",
                                     icon: "arrow.triangle.branch") { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["diff"]) { DiffTab(uri: $0, app: app) },
                  TabProvider(schemes: ["commit"]) { CommitMessageTab(uri: $0, app: app) }]
        let changed = ChangedFiles(app: app)
        c.panels = [PanelSpec(id: "git.changes", title: "Source Control", icon: "arrow.triangle.branch", extensionId: "kelp.git",
                              badge: { changed.count > 0 ? PanelBadge(count: changed.count) : nil }) { SourceControlController(app: app) }]
        c.editors = [EditorSpec(id: "git.review", title: "Review Changes", icon: "plusminus", uri: { ctx in ctx.workspace.map { DiffTab.uri($0.id) } })]
        c.settings = [SettingsSection(id: "git", title: "Git", icon: "arrow.triangle.branch", specs: [
            s("git.branchPrefix", "Branch prefix", "string", "", "Added to branches Kelp names, e.g. “niko/”.")
        ])]
        c.commands = [
            CommandSpec(id: "git.review", title: "Git: Review Changes", key: "shift+cmd+r") { _ in
                if let w = app.workbench.workspaceId { app.workbench.open(DiffTab.uri(w)) }
            },
            CommandSpec(id: "git.pullRequest", title: "Git: Create Pull Request") { _ in
                if let w = app.workbench.workspaceId { PRActions(app).create(worktree: w) }
            },
            CommandSpec(id: "git.push", title: "Git: Push") { _ in
                if let w = app.workbench.workspaceId {
                    Task { if await app.call(GitPush(id: w)) != nil { Banner.show(String(localized: "Pushed")) } }
                }
            }
        ]
        return c
    }
}
