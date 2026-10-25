import AppKit
import SwiftUI
import Core
import Agents
import WorkbenchKit
import KelpKit

extension Builtins {

    package static let agents = Builtin("kelp.agents", "Agents & Terminals", "Agent sessions and terminals as tabs.",
                                        icon: "sparkles", essential: true) { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["session"], make: { SessionTab(uri: $0, app: app) },
                              closeUnbuilt: { await SessionTab.close(app, session: TabURI.body($0)) },
                              menu: { SessionTab.menu(app, $0, uri: $1, workspace: $2, openBeside: $3) })]
        c.tabs.append(TabProvider(schemes: ["usage"]) { _ in UsageTab(app: app) })
        c.settings = [
            SettingsSection(id: "agents", title: "Agents", icon: "sparkles", specs: [
                s("agents.default", "Default agent", "enum", "claude", "Used by New Agent (⌥⌘T).", options: app.catalog.all.map(\.id)),
                s("agents.skills.extensions", "Skill: write Kelp extensions", "boolean", true,
                  "Claude Code knows where an extension goes, its format and how to connect it. Ask it for a panel, tab or command."),
                s("agents.skills.settings", "Skill: change Kelp settings", "boolean", true,
                  "Claude Code can read and change these settings (theme, fonts, extensions…) when you ask."),
                s("agents.skills.terminals", "Skill: run commands in Kelp tabs", "boolean", true,
                  "Claude Code runs tests or a dev server in a tab beside it, waits for them and reads what they printed, and shows its progress on its row."),
                s("sessions.hibernateMinutes", "Pause idle agents", "number", 0, "Paused agents free memory and resume the same conversation.",
                  options: ["0", "15", "30", "60", "240"]),
                s("power.keepAwake", "Keep Mac awake", "enum", "agents", options: ["agents", "always", "off"]),
                s("usage.readPlans", "Show plan limits", "boolean", true,
                  "Opens /usage of Claude Code (every 10 minutes), Grok, Antigravity, Kimi, Copilot and Cursor (every 30) in the background, asks Codex for its limits "
                    + "(every 10 minutes) and shows how much of each plan is used at the bottom of the sidebar. Uses no tokens."),
                s("usage.alertAt", "Warn about limits at (%)", "enum", "80", "A notification when a plan limit reaches this, and again at 95. “off”: none.",
                  options: ["off", "70", "80", "90"])
            ], custom: { AnyView(VStack(alignment: .leading, spacing: 16) { AgentsSettings(app: app).frame(height: 300); AccountsSettings(app: app) }) }),
            SettingsSection(id: "terminal", title: "Terminal", icon: "terminal", specs: [
                s("terminal.fontFamily", "Font", "font", "", "Default: the theme's / Ghostty's font."),
                s("terminal.fontSize", "Font size", "number", 13),
                s("terminal.cursorStyle", "Cursor", "enum", "block", options: ["block", "bar", "underline"]),
                s("terminal.optionAsAlt", "Option key sends Alt (Meta)", "boolean", false),
                s("terminal.cleanCopy", "Copy text without the TUI around it", "boolean", true,
                  "Drops box borders, an agent's indented gutter and trailing spaces from what you copy, and joins the lines an agent wrapped at the edge (a long command copies as one line)."),
                s("terminal.useGhosttyConfig", "Also read ~/.config/ghostty/config", "boolean", false,
                  "Keybindings and other Ghostty options; the theme's colors still apply."),
                s("terminal.tmux", "Run terminals inside tmux", "boolean", false,
                  "New terminals run in a tmux session of their own (on the host, for a remote project): it keeps running when Kelp quits or "
                    + "updates, and the tab attaches to it again; after a dropped SSH connection, Restart does. Closing the tab ends the session. "
                    + "Needs tmux; without it here, terminals are plain shells.")
            ])
        ]
        c.commands = [
            CommandSpec(id: "agents.new", title: "New Agent", key: "opt+cmd+t") { args in
                editor(app)?.newAgent(args["agent"]?.string, prompt: args["prompt"]?.string)
            },
            cmd("terminal.new", "New Terminal", "cmd+t") { editor(app)?.newTerminal() },
            cmd("terminal.tmux", "Attach to tmux Session…") { app.quickOpen.showTmux() },
            cmd("terminal.splitRight", "Split Right", "cmd+d") { editor(app)?.splitFocused(.right) },
            cmd("terminal.splitDown", "Split Down", "shift+cmd+d") { editor(app)?.splitFocused(.down) },
            cmd("agents.sideBySide", "Agents Side by Side", "ctrl+cmd+t") { editor(app)?.toggleSideBySide() },
            cmd("agents.nextNeedingYou", "Show Agent Needing You", "shift+cmd+u") { app.workbench.showNextNeedingAttention() },
            cmd("agents.usage", "Usage", "opt+cmd+u") { app.workbench.open("usage:") },
            cmd("agents.history", "Session History", "shift+cmd+h") { app.historyWindow.show() },
            // Like Caffeine: ticked keeps the Mac awake until unticked, which goes back to the setting's default.
            cmd("power.keepAwake", "Keep Mac Awake") {
                app.settings.set("power.keepAwake", app.settings.string("power.keepAwake") == "always" ? nil : .string("always"))
            }
        ]
        return c
    }
}
