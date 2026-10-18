import Foundation
import Core

/// An agent is data, not code: adding one means adding a JSON file to ~/.krill/agents.
public struct AgentManifest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [String: String]
    /// Regexes matched against the tail of recent output when the agent goes quiet: it is asking the user something.
    public var waitingPatterns: [String]
    /// Seconds without output before the heuristic decides the agent stopped.
    public var quietSeconds: Double
    /// If set, hooks are supported: `{hooksSettingsFlag} <file>` is appended and the file holds Stop/Notification hooks.
    public var hooksSettingsFlag: String?

    public init(id: String, name: String, command: String, args: [String] = [], env: [String: String] = [:],
                waitingPatterns: [String] = AgentManifest.defaultWaiting, quietSeconds: Double = 3, hooksSettingsFlag: String? = nil) {
        self.id = id; self.name = name; self.command = command; self.args = args; self.env = env
        self.waitingPatterns = waitingPatterns; self.quietSeconds = quietSeconds; self.hooksSettingsFlag = hooksSettingsFlag
    }

    public static let defaultWaiting = [
        #"(?i)\[y/n\]"#, #"(?i)\(y/n\)"#, #"(?i)do you want to"#, #"(?i)press enter"#,
        #"(?i)allow .* to"#, #"(?i)approve"#, #"❯ ?1\."#,
    ]

    public var commandLine: [String] { [command] + args }

    public static let presets: [AgentManifest] = [
        .init(id: "claude", name: "Claude Code", command: "claude", hooksSettingsFlag: "--settings"),
        .init(id: "codex", name: "Codex", command: "codex"),
        .init(id: "opencode", name: "OpenCode", command: "opencode"),
        .init(id: "gemini", name: "Gemini CLI", command: "gemini"),
        .init(id: "cursor", name: "Cursor Agent", command: "cursor-agent"),
        .init(id: "pi", name: "Pi", command: "pi"),
        .init(id: "amp", name: "Amp", command: "amp"),
    ]

    /// Presets overridden/extended by `*.json` files in `dir`. Bad files are skipped, never fatal.
    public static func load(dir: URL = Paths.agents) -> [AgentManifest] {
        var all = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let m = try? JSONDecoder().decode(AgentManifest.self, from: d) { all[m.id] = m }
        }
        return all.values.sorted { $0.name < $1.name }
    }

    /// A "custom command" agent: any shell command.
    public static func custom(_ command: String) -> AgentManifest {
        .init(id: "custom", name: "Custom", command: "/bin/zsh", args: ["-lc", command])
    }
}

public enum Hooks {
    /// Claude-style settings file: Stop → done, Notification → waiting. `krill` must be on PATH in the session.
    public static func settingsJSON() -> String {
        func hook(_ ev: String) -> String { #"[{"hooks":[{"type":"command","command":"krill hook \#(ev)"}]}]"# }
        return #"{"hooks":{"Stop":\#(hook("done")),"Notification":\#(hook("waiting")),"UserPromptSubmit":\#(hook("working"))}}"#
    }

    public static func writeSettings(to url: URL) throws {
        try Paths.ensure(url.deletingLastPathComponent())
        try settingsJSON().write(to: url, atomically: true, encoding: .utf8)
    }
}
