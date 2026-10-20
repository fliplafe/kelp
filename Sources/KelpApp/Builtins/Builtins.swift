import AppKit
import SwiftUI
import Core
import Agents

/// A built-in extension: same contribution points as an extension.json folder, implemented in Swift.
@MainActor
struct Builtin {
    let info: ExtensionInfo
    let contribute: @MainActor () -> Contributions

    init(_ id: String, _ name: String, _ description: String, icon: String, essential: Bool = false, _ contribute: @escaping @MainActor () -> Contributions) {
        info = ExtensionInfo(id: id, name: name, description: description, version: "built-in", icon: icon, builtin: true, essential: essential, enabled: true)
        self.contribute = contribute
    }
}

@MainActor
enum Builtins {
    static let all: [Builtin] = [agents, appearance, files, git, browser, issues, activity]

    private static func s(_ key: String, _ title: String, _ type: String, _ def: JSONValue?, _ desc: String? = nil, options: [String]? = nil) -> SettingSpec {
        SettingSpec(key: key, title: title, type: type, default: def, description: desc, options: options)
    }

    static let agents = Builtin("kelp.agents", "Agents & Terminals", "Agent sessions and terminals as tabs.", icon: "sparkles", essential: true) {
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["session"], extensionId: "kelp.agents") { SessionTab(uri: $0) }]
        c.tabs.append(TabProvider(schemes: ["usage"], extensionId: "kelp.agents") { _ in UsageTab() })
        c.settings = [
            SettingsSection(id: "agents", title: "Agents", icon: "sparkles", extensionId: "kelp.agents", specs: [
                s("agents.default", "Default agent", "enum", "claude", "Used by New Agent (⌥⌘T).", options: AgentCatalog.all.map(\.id)),
                s("agents.skills.extensions", "Skill: write Kelp extensions", "boolean", true,
                  "Claude Code knows where an extension goes, its format and how to connect it. Ask it for a panel, tab or command."),
                s("agents.skills.settings", "Skill: change Kelp settings", "boolean", true,
                  "Claude Code can read and change these settings (theme, fonts, extensions…) when you ask."),
                s("sessions.hibernateMinutes", "Pause idle agents", "number", 0, "Paused agents free memory and resume the same conversation.",
                  options: ["0", "15", "30", "60", "240"]),
                s("power.keepAwake", "Keep Mac awake", "enum", "agents", options: ["agents", "always", "off"]),
                s("usage.readPlans", "Show plan limits", "boolean", true,
                  "Opens /usage of Claude Code (every 10 minutes), Grok and Antigravity (every 30) in the background and shows how much of each plan is used at the bottom of the sidebar. Uses no tokens.")
            ], custom: { AnyView(VStack(alignment: .leading, spacing: 16) { AgentsSettings().frame(height: 300); AccountsSettings() }) }),
            SettingsSection(id: "terminal", title: "Terminal", icon: "terminal", extensionId: "kelp.agents", specs: [
                s("terminal.fontFamily", "Font", "font", "", "Empty = the theme's / Ghostty's font."),
                s("terminal.fontSize", "Font size", "number", 13),
                s("terminal.cursorStyle", "Cursor", "enum", "block", options: ["block", "bar", "underline"]),
                s("terminal.optionAsAlt", "Option key sends Alt (Meta)", "boolean", false),
                s("terminal.cleanCopy", "Copy text without the TUI around it", "boolean", true,
                  "Drops box borders, an agent's indented gutter and trailing spaces from what you copy."),
                s("terminal.useGhosttyConfig", "Also read ~/.config/ghostty/config", "boolean", false, "Keybindings and other Ghostty options; the theme's colors still apply.")
            ])
        ]
        c.commands = [
            CommandSpec(id: "agents.new", title: "New Agent", extensionId: "kelp.agents", key: "opt+cmd+t") { args in Workbench.editor?.newAgent(args["agent"]?.string, prompt: args["prompt"]?.string) },
            CommandSpec(id: "terminal.new", title: "New Terminal", extensionId: "kelp.agents", key: "cmd+t") { _ in Workbench.editor?.newTerminal() },
            CommandSpec(id: "terminal.splitRight", title: "Split Right", extensionId: "kelp.agents", key: "cmd+d") { _ in Workbench.editor?.splitFocused(.right) },
            CommandSpec(id: "terminal.splitDown", title: "Split Down", extensionId: "kelp.agents", key: "shift+cmd+d") { _ in Workbench.editor?.splitFocused(.down) }
        ]
        return c
    }

    static let files = Builtin("kelp.files", "Files & Editor", "File tree, search and the code editor (tree-sitter, LSP).", icon: "doc.text", essential: true) {
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["file"], extensionId: "kelp.files") { FileTab(uri: $0) },
                  TabProvider(schemes: ["untitled"], extensionId: "kelp.files") { UntitledTab(uri: $0) }]
        c.panels = [PanelSpec(id: "files", title: "Files", icon: "folder", extensionId: "kelp.files") { FilesPanel() }]
        c.editors = [EditorSpec(id: "files.new", title: "New File", icon: "doc.badge.plus", extensionId: "kelp.files") { _ in UntitledTab.next() }]
        c.settings = [SettingsSection(id: "editor", title: "Editor", icon: "doc.text", extensionId: "kelp.files", specs: [
            s("editor.fontFamily", "Font", "font", "", "Empty = SF Mono."),
            s("editor.fontSize", "Font size", "number", 13),
            s("editor.minimap", "Show minimap", "boolean", false),
            s("editor.autoSave", "Save automatically", "boolean", false, "Off: edited files show a dot and you save with ⌘S. On: they save a moment after you stop typing."),
            s("editor.lsp", "Language servers (errors, completion, jump to definition)", "boolean", true)
        ])]
        c.commands = [CommandSpec(id: "files.quickOpen", title: "Open File…", extensionId: "kelp.files", key: "cmd+p") { _ in QuickOpen.shared.show(commandsOnly: false) },
                      CommandSpec(id: "files.new", title: "New File", extensionId: "kelp.files", key: "opt+cmd+n") { _ in Workbench.open(UntitledTab.next()) },
                      CommandSpec(id: "markdown.cycleView", title: "Markdown: Source, Split, Preview", extensionId: "kelp.files", key: "shift+cmd+v") { _ in
                          guard let md = (Workbench.editor?.focusedContent as? FileTab)?.markdown else { NSSound.beep(); return }
                          md.cycleMode()
                      }]
        return c
    }

    static let git = Builtin("kelp.git", "Git", "Source Control: changes and staging, commits, branches, the history graph and diffs.", icon: "arrow.triangle.branch") {
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["diff"], extensionId: "kelp.git") { DiffTab(uri: $0) },
                  TabProvider(schemes: ["commit"], extensionId: "kelp.git") { CommitMessageTab(uri: $0) }]
        c.panels = [PanelSpec(id: "git.changes", title: "Source Control", icon: "arrow.triangle.branch", extensionId: "kelp.git",
                              badge: { ChangedFiles.shared.count }) { SourceControlController() }]
        c.editors = [EditorSpec(id: "git.review", title: "Review Changes", icon: "plusminus", extensionId: "kelp.git", uri: { ctx in ctx.workspace.map { DiffTab.uri($0.id) } })]
        c.settings = [SettingsSection(id: "git", title: "Git", icon: "arrow.triangle.branch", extensionId: "kelp.git", specs: [
            s("git.branchPrefix", "Branch prefix", "string", "", "Added to branches Kelp names, e.g. “niko/”.")
        ])]
        c.commands = [
            CommandSpec(id: "git.review", title: "Git: Review Changes", extensionId: "kelp.git", key: "shift+cmd+r") { _ in
                if let w = Workbench.shared.workspaceId { Workbench.open(DiffTab.uri(w)) }
            },
            CommandSpec(id: "git.pullRequest", title: "Git: Create Pull Request", extensionId: "kelp.git") { _ in
                if let w = Workbench.shared.workspaceId { PRActions.create(worktree: w) }
            },
            CommandSpec(id: "git.push", title: "Git: Push", extensionId: "kelp.git") { _ in
                if let w = Workbench.shared.workspaceId { Task { if await AppModel.shared.call("git.push", .obj(["id": .string(w)])) != nil { Banner.show(String(localized: "Pushed")) } } }
            }
        ]
        return c
    }

    /// Off on a clean install (`ExtensionRegistry.offByDefault`): Settings › Extensions turns it on.
    static let activity = Builtin("kelp.activity", "Activity", "CPU and memory of each agent and terminal, with Stop.", icon: "gauge.with.dots.needle.33percent") {
        var c = Contributions()
        c.panels = [PanelSpec(id: "activity", title: "Activity", icon: "gauge.with.dots.needle.33percent", extensionId: "kelp.activity") { ActivityController() }]
        return c
    }

    static let browser = Builtin("kelp.browser", "Browser", "Web pages as tabs, dev servers open automatically, Design Mode.", icon: "safari") {
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["http", "https", "about", "preview"], extensionId: "kelp.browser") { BrowserTab(uri: $0) }]
        c.editors = [EditorSpec(id: "browser.new", title: "Browser", icon: "safari", extensionId: "kelp.browser", uri: { _ in "about:blank#\(UUID().uuidString.prefix(6))" })]
        c.commands = [CommandSpec(id: "browser.new", title: "New Browser Tab", extensionId: "kelp.browser", key: "shift+cmd+b") { args in
            Workbench.open(args["url"]?.string ?? "about:blank#\(UUID().uuidString.prefix(6))")
        }]
        return c
    }

    static let issues = Builtin("kelp.issues", "Issues & Pull Requests", "GitHub, Linear, Jira and Bitbucket: start work from an issue, review PRs.", icon: "checklist") {
        var c = Contributions()
        c.panels = [PanelSpec(id: "issues", title: "Issues & PRs", icon: "checklist", extensionId: "kelp.issues") {
            let t = TasksViewController()
            track { Workbench.shared.workspaceId } changed: { [weak t] in t?.show(worktree: $0) }
            return t
        }, PanelSpec(id: "ci", title: "CI Runs", icon: "checkmark.seal", extensionId: "kelp.issues") { CIRunsController() }]
        c.settings = [SettingsSection(id: "integrations", title: "Integrations", icon: "link", extensionId: "kelp.issues", specs: [],
                                      custom: { AnyView(IntegrationsSettings()) })]
        return c
    }

    static let appearance = Builtin("kelp.appearance", "Appearance", "Themes for the window, terminal and editor.", icon: "paintpalette", essential: true) {
        var c = Contributions()
        c.settings = [SettingsSection(id: "appearance", title: "Appearance", icon: "paintpalette", extensionId: "kelp.appearance", specs: [
            s("workbench.theme", "Theme", "theme", "auto",
              "The window, terminal and editor together. Match System switches Kelp Light / Dark with macOS; Ghostty keeps your Ghostty terminal colors."),
            s("workbench.iconTheme", "File Icons", "enum", .string(FileIcon.system),
              "Icons in Files, Source Control and tabs. VS Code icon themes work as they are: Settings › Extensions › Install…"),
            s("workbench.textSize", "Sidebar and inspector text", "enum", "normal", "The terminal and the editor have their own font sizes.",
              options: ["normal", "large", "larger"]),
            s("workbench.inspectorIcons", "Inspector icons", "enum", "center", "Where the panel icons sit above the inspector.",
              options: ["left", "center", "right"]),
            s("workbench.sidebar.autoHide", "Auto-hide sidebar", "boolean", false, "Comes in while the pointer is at the window's left edge, like the Dock."),
            s("workbench.inspector.autoHide", "Auto-hide inspector", "boolean", false, "Comes in while the pointer is at the window's right edge.")
        ]), SettingsSection(id: "keyboard", title: "Keyboard", icon: "keyboard", extensionId: "kelp.appearance", specs: [],
                            custom: { AnyView(KeyboardSettings()) })]
        return c
    }
}
