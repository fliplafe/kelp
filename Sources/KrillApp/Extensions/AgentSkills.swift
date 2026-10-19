import Foundation
import Core

/// Krill's skills for agents: how to write and connect an extension, how to change settings. Each is a Claude Code
/// plugin in ~/.krill/agent-skills that the daemon loads per session (--plugin-dir); turning one off in
/// Settings › Agents removes it. Nothing is written to the agent's own config.
@MainActor
enum AgentSkills {
    static func write() {
        let s = SettingsStore.shared
        put("krill-extensions", on: s.bool("agents.skills.extensions") != false,
            description: "Use when the user wants something added to or changed in Krill, the IDE this session runs in: a panel, list, tab, command, "
                + "setting or theme — e.g. “add a Krill panel with my Docker containers”, “show Android emulators in Krill”. Krill extensions are "
                + "extension.json folders in $KRILL_HOME/extensions; they are not Claude Code plugins, mods, hooks or MCP servers.",
            body: extensionsSteps(ExtensionRegistry.userDir.path) + ExtensionGuide.markdown)
        put("krill-settings", on: s.bool("agents.skills.settings") != false,
            description: "Use when the user wants to see or change how Krill, the IDE this session runs in, is set up: theme, fonts, editor, "
                + "terminal, agents, turning extensions on or off. Done with the krill CLI (krill settings set …), not Claude Code's own settings.",
            body: settingsGuide())
        // The guide also sits next to the user's extensions, for people.
        let guide = ExtensionRegistry.userDir.appendingPathComponent("EXTENSIONS.md")
        writeIfChanged(guide, ExtensionGuide.markdown)
    }

    /// The exact folder this Krill loads extensions from (the guide below says ~/.krill, which a custom KRILL_HOME changes).
    private static func extensionsSteps(_ folder: String) -> String { """
        # Adding something to Krill

        This session runs inside Krill and the `krill` CLI is on PATH. Krill loads extensions from `\(folder)`.

        1. Write `\(folder)/<id>/extension.json` (and any script or HTML it uses next to it) following the guide below.
           Prefer a `list` view fed by a shell command that prints one JSON object per line.
        2. Run `krill ext reload`, then `krill ext list` — fix the manifest if it reports an error.
        3. Tell the user where it appears (right inspector icon for panels, the + menu for tabs) and how to use it.

        Never use Claude Code plugins, mods, hooks or MCP for this: Krill only loads its own extension folders.

        ---


        """
    }

    private static func put(_ name: String, on: Bool, description: String, body: String) {
        let plugin = Paths.agentSkills.appendingPathComponent(name)
        guard on else { try? FileManager.default.removeItem(at: plugin); return }
        let manifest: [String: Any] = ["name": name, "version": "1.0.0", "description": description, "author": ["name": "Krill"]]
        if let d = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]), let json = String(bytes: d, encoding: .utf8) {
            writeIfChanged(plugin.appendingPathComponent(".claude-plugin/plugin.json"), json)
        }
        let front = "---\nname: \(name)\ndescription: \(description)\n---\n\n"
        writeIfChanged(plugin.appendingPathComponent("skills/\(name)/SKILL.md"), front + body)
    }

    private static func writeIfChanged(_ url: URL, _ text: String) {
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Every setting the installed extensions declare, with how to change it.
    static func settingsGuide() -> String {
        var out = """
        # Krill settings

        Krill keeps its settings in `$KRILL_HOME/settings.json` (one flat object with dotted keys). Change them with the
        `krill` CLI, which is on PATH in every Krill session; the app applies changes immediately.

        - `krill settings` — all current values
        - `krill settings get <key>`
        - `krill settings set <key> <value>` — the value is JSON when it parses (`true`, `14`, `["a"]`), else text
        - `krill settings unset <key>` — back to the default
        - `krill ext list` / `krill ext enable <id>` / `krill ext disable <id>` — turn extensions on or off

        Only change what the user asked for, then say what you changed.

        ## Keys

        | Key | Type | Default | What it does |
        | --- | --- | --- | --- |

        """
        for section in ExtensionRegistry.shared.all.settings {
            for spec in section.specs {
                var type = spec.type
                if let o = spec.options, !o.isEmpty { type += ": " + o.joined(separator: " / ") }
                let def = spec.default.map { v -> String in
                    if case .string(let s) = v { return s.isEmpty ? "—" : s }
                    return (try? JSONEncoder().encode(v)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "—"
                } ?? "—"
                let what = [spec.title, spec.description].compactMap { $0 }.joined(separator: ". ").replacingOccurrences(of: "|", with: "/")
                out += "| `\(spec.key)` | \(type) | \(def) | \(what) |\n"
            }
        }
        out += "\nThemes for `workbench.theme`: auto, ghostty, " + ThemeManager.shared.themes.map(\.id).joined(separator: ", ") + ".\n"
        out += "File icon themes for `workbench.iconTheme`: " + FileIcon.themes.map(\.id).joined(separator: ", ") + ".\n"
        return out
    }
}
