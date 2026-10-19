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
    static let all: [Builtin] = [agents, appearance, files, git, browser, issues]

    private static func s(_ key: String, _ title: String, _ type: String, _ def: JSONValue?, _ desc: String? = nil, options: [String]? = nil) -> SettingSpec {
        SettingSpec(key: key, title: title, type: type, default: def, description: desc, options: options)
    }

    static let agents = Builtin("krill.agents", "Agents & Terminals", "Agent sessions and terminals as tabs.", icon: "sparkles", essential: true) {
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["session"], extensionId: "krill.agents") { SessionTab(uri: $0) }]
        c.settings = [
            SettingsSection(id: "agents", title: "Agents", icon: "sparkles", extensionId: "krill.agents", specs: [
                s("agents.default", "Default agent", "enum", "claude", "Used by New Agent (⌥⌘T).", options: AgentCatalog.all.map(\.id)),
                s("agents.skills.extensions", "Skill: write Krill extensions", "boolean", true,
                  "Claude Code knows where an extension goes, its format and how to connect it. Ask it for a panel, tab or command."),
                s("agents.skills.settings", "Skill: change Krill settings", "boolean", true,
                  "Claude Code can read and change these settings (theme, fonts, extensions…) when you ask."),
                s("sessions.hibernateMinutes", "Pause idle agents after (minutes)", "number", 0, "0 = never. Paused agents free memory and resume the same conversation."),
                s("power.keepAwake", "Keep Mac awake", "enum", "agents", options: ["agents", "always", "off"]),
                s("usage.readClaudePlan", "Show Claude plan limits", "boolean", true,
                  "Opens Claude Code's /usage in the background every 10 minutes and shows the percentages in the sidebar. Uses no tokens.")
            ], custom: { AnyView(VStack(alignment: .leading, spacing: 16) { AgentsSettings().frame(height: 300); AccountsSettings() }) }),
            SettingsSection(id: "terminal", title: "Terminal", icon: "terminal", extensionId: "krill.agents", specs: [
                s("terminal.fontFamily", "Font", "font", "", "Empty = the theme's / Ghostty's font."),
                s("terminal.fontSize", "Font size", "number", 13),
                s("terminal.cursorStyle", "Cursor", "enum", "block", options: ["block", "bar", "underline"]),
                s("terminal.optionAsAlt", "Option key sends Alt (Meta)", "boolean", false),
                s("terminal.useGhosttyConfig", "Also read ~/.config/ghostty/config", "boolean", false, "Keybindings and other Ghostty options; the theme's colors still apply.")
            ])
        ]
        c.commands = [
            CommandSpec(id: "agents.new", title: "New Agent", extensionId: "krill.agents", key: "opt+cmd+t") { args in Workbench.editor?.newAgent(args["agent"]?.string, prompt: args["prompt"]?.string) },
            CommandSpec(id: "terminal.new", title: "New Terminal", extensionId: "krill.agents", key: "cmd+t") { _ in Workbench.editor?.newTerminal() },
            CommandSpec(id: "terminal.splitRight", title: "Split Right", extensionId: "krill.agents", key: "cmd+d") { _ in Workbench.editor?.splitFocused(.right) },
            CommandSpec(id: "terminal.splitDown", title: "Split Down", extensionId: "krill.agents", key: "shift+cmd+d") { _ in Workbench.editor?.splitFocused(.down) }
        ]
        return c
    }

    static let files = Builtin("krill.files", "Files & Editor", "File tree, search and the code editor (tree-sitter, LSP).", icon: "doc.text", essential: true) {
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["file"], extensionId: "krill.files") { FileTab(uri: $0) }]
        c.panels = [PanelSpec(id: "files", title: "Files", icon: "folder", extensionId: "krill.files") { FilesPanel() }]
        c.settings = [SettingsSection(id: "editor", title: "Editor", icon: "doc.text", extensionId: "krill.files", specs: [
            s("editor.fontFamily", "Font", "font", "", "Empty = SF Mono."),
            s("editor.fontSize", "Font size", "number", 13),
            s("editor.minimap", "Show minimap", "boolean", false),
            s("editor.autoSave", "Save automatically", "boolean", false, "Off: edited files show a dot and you save with ⌘S. On: they save a moment after you stop typing."),
            s("editor.lsp", "Language servers (errors, completion, jump to definition)", "boolean", true)
        ])]
        c.commands = [CommandSpec(id: "files.quickOpen", title: "Open File…", extensionId: "krill.files", key: "cmd+p") { _ in QuickOpen.shared.show(commandsOnly: false) }]
        return c
    }

    static let git = Builtin("krill.git", "Git", "Source Control: changes and staging, commits, branches, the history graph and diffs.", icon: "arrow.triangle.branch") {
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["diff"], extensionId: "krill.git") { DiffTab(uri: $0) }]
        c.panels = [PanelSpec(id: "git.changes", title: "Source Control", icon: "arrow.triangle.branch", extensionId: "krill.git") { SourceControlController() }]
        c.editors = [EditorSpec(id: "git.review", title: "Review Changes", icon: "plusminus", extensionId: "krill.git", uri: { ctx in ctx.workspace.map { DiffTab.uri($0.id) } })]
        c.settings = [SettingsSection(id: "git", title: "Git", icon: "arrow.triangle.branch", extensionId: "krill.git", specs: [
            s("git.branchPrefix", "Branch prefix", "string", "", "Added to branches Krill names, e.g. “niko/”.")
        ])]
        c.commands = [
            CommandSpec(id: "git.review", title: "Git: Review Changes", extensionId: "krill.git", key: "shift+cmd+r") { _ in
                if let w = Workbench.shared.workspaceId { Workbench.open(DiffTab.uri(w)) }
            },
            CommandSpec(id: "git.pullRequest", title: "Git: Create Pull Request", extensionId: "krill.git") { _ in
                if let w = Workbench.shared.workspaceId { PRActions.create(worktree: w) }
            },
            CommandSpec(id: "git.push", title: "Git: Push", extensionId: "krill.git") { _ in
                if let w = Workbench.shared.workspaceId { Task { if await AppModel.shared.call("git.push", .obj(["id": .string(w)])) != nil { Banner.show("Pushed") } } }
            }
        ]
        return c
    }

    static let browser = Builtin("krill.browser", "Browser", "Web pages as tabs, dev servers open automatically, Design Mode.", icon: "safari") {
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["http", "https", "about"], extensionId: "krill.browser") { BrowserTab(uri: $0) }]
        c.editors = [EditorSpec(id: "browser.new", title: "Browser", icon: "safari", extensionId: "krill.browser", uri: { _ in "about:blank#\(UUID().uuidString.prefix(6))" })]
        c.commands = [CommandSpec(id: "browser.new", title: "New Browser Tab", extensionId: "krill.browser", key: "shift+cmd+b") { args in
            Workbench.open(args["url"]?.string ?? "about:blank#\(UUID().uuidString.prefix(6))")
        }]
        return c
    }

    static let issues = Builtin("krill.issues", "Issues & Pull Requests", "GitHub, Linear, Jira and Bitbucket: start work from an issue, review PRs.", icon: "checklist") {
        var c = Contributions()
        c.panels = [PanelSpec(id: "issues", title: "Issues & PRs", icon: "checklist", extensionId: "krill.issues") {
            let t = TasksViewController()
            track { Workbench.shared.workspaceId } changed: { [weak t] in t?.show(worktree: $0) }
            return t
        }]
        c.settings = [SettingsSection(id: "integrations", title: "Integrations", icon: "link", extensionId: "krill.issues", specs: [],
                                      custom: { AnyView(IntegrationsSettings()) })]
        return c
    }

    static let appearance = Builtin("krill.appearance", "Appearance", "Light / dark, color themes for terminal and editor.", icon: "paintpalette", essential: true) {
        var c = Contributions()
        c.settings = [SettingsSection(id: "appearance", title: "Appearance", icon: "paintpalette", extensionId: "krill.appearance", specs: [
            s("workbench.appearance", "Appearance", "enum", "system", "With the Auto and Ghostty themes; a light or dark theme sets the window to match.",
              options: ["system", "light", "dark"]),
            s("workbench.theme", "Color theme", "enum", "auto", "Terminal and editor colors. Auto follows light / dark; Ghostty config keeps your Ghostty colors.")
        ])]
        return c
    }
}
