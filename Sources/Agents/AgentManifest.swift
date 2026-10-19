import Foundation
import Core

/// An agent is data, not code: adding one means adding a JSON file to ~/.krill/agents.
/// Only `id`, `name` and `command` are required in a file; everything else has defaults.
public struct AgentManifest: Codable, Sendable, Equatable, Identifiable {
    public struct AutoAnswer: Codable, Sendable, Equatable {
        public var pattern: String; public var input: String
        /// For arrow-key menus: regex of the option to pick; the keys are computed from where the cursor (❯ / >) is.
        public var choose: String?
        public init(pattern: String, input: String, choose: String? = nil) { self.pattern = pattern; self.input = input; self.choose = choose }

        /// Text of the option under a TUI menu's cursor. TUIs redraw only changed lines, so it's what follows the last ❯ in the stream.
        public static func optionAtCursor(_ screen: String) -> String? {
            guard let mark = screen.range(of: "❯", options: .backwards) ?? screen.range(of: "›", options: .backwards) else { return nil }
            // split on isNewline: "\r\n" is a single Character, so splitting on "\n" alone would glue options together
            return String(screen[mark.upperBound...].prefix(80).split(whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: .whitespaces)
        }

        /// Keys that move a TUI menu's cursor onto the option matching `choose` and confirm it. nil if no menu is visible yet.
        public static func menuKeys(screen: String, choose: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: choose) else { return nil }
            let lines = screen.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let cur = lines.lastIndex(where: { $0.hasPrefix("❯") || $0.hasPrefix(">") || $0.hasPrefix("›") }) else { return nil }
            // The menu is the run of non-empty lines around the cursor line.
            var lo = cur, hi = cur
            while lo > 0, !lines[lo - 1].isEmpty { lo -= 1 }
            while hi + 1 < lines.count, !lines[hi + 1].isEmpty { hi += 1 }
            let match = { (l: String) in re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil }
            // Options, not the question above them; the nearest match to the cursor wins.
            guard let target = (lo...hi).filter({ !lines[$0].hasSuffix("?") && match(lines[$0]) }).min(by: { abs($0 - cur) < abs($1 - cur) }) else { return nil }
            let step = target - cur
            return String(repeating: step > 0 ? "\u{1B}[B" : "\u{1B}[A", count: abs(step)) + "\r"
        }
    }

    public var id: String
    public var name: String
    public var command: String
    public var args: [String] = []
    public var env: [String: String] = [:]
    /// Regexes matched against the tail of recent output when the agent goes quiet: it is asking the user something.
    public var waitingPatterns: [String] = AgentManifest.defaultWaiting
    /// Seconds without output before the heuristic decides the agent stopped.
    public var quietSeconds: Double = 3
    /// If set, hooks are supported: `{hooksSettingsFlag} <file>` is appended and the file holds Stop/Notification hooks.
    public var hooksSettingsFlag: String?
    /// Extra args for "Yolo" permission mode (skip approval prompts).
    public var yoloArgs: [String] = []
    /// `--model`-style flag and suggested models for the picker.
    public var modelFlag: String?
    public var models: [String] = []
    /// Effort level -> extra args.
    public var effortArgs: [String: [String]] = [:]
    /// Prompts answered automatically in the first seconds of a session (e.g. "trust this folder?").
    public var autoAnswers: [AutoAnswer] = []
    /// Args that resume the latest conversation in this directory (restart / hibernation) when no id was pinned.
    public var resumeArgs: [String] = []
    /// `--session-id <uuid>` pins a new conversation to the Krill session id; `--resume <uuid>` brings back exactly that one.
    /// Without them, two agents in one folder resume each other's conversations.
    public var sessionIdFlag: String?
    public var resumeIdFlag: String?
    /// If set, `{pluginDirFlag} <dir>` loads Krill's skills (extensions, settings) for the session only.
    public var pluginDirFlag: String?
    /// If set, `{contextFlag} <text>` tells the agent it runs inside Krill and which skills to use for it.
    public var contextFlag: String?

    public init(id: String, name: String, command: String, args: [String] = [], env: [String: String] = [:],
                waitingPatterns: [String] = AgentManifest.defaultWaiting, quietSeconds: Double = 3, hooksSettingsFlag: String? = nil,
                yoloArgs: [String] = [], modelFlag: String? = nil, models: [String] = [], effortArgs: [String: [String]] = [:],
                autoAnswers: [AutoAnswer] = [], resumeArgs: [String] = [], pluginDirFlag: String? = nil, contextFlag: String? = nil,
                sessionIdFlag: String? = nil, resumeIdFlag: String? = nil) {
        self.id = id; self.name = name; self.command = command; self.args = args; self.env = env
        self.waitingPatterns = waitingPatterns; self.quietSeconds = quietSeconds; self.hooksSettingsFlag = hooksSettingsFlag
        self.yoloArgs = yoloArgs; self.modelFlag = modelFlag; self.models = models; self.effortArgs = effortArgs
        self.autoAnswers = autoAnswers; self.resumeArgs = resumeArgs; self.pluginDirFlag = pluginDirFlag; self.contextFlag = contextFlag
        self.sessionIdFlag = sessionIdFlag; self.resumeIdFlag = resumeIdFlag
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentManifest(id: "", name: "", command: "")
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? d.args
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? d.env
        waitingPatterns = try c.decodeIfPresent([String].self, forKey: .waitingPatterns) ?? d.waitingPatterns
        quietSeconds = try c.decodeIfPresent(Double.self, forKey: .quietSeconds) ?? d.quietSeconds
        hooksSettingsFlag = try c.decodeIfPresent(String.self, forKey: .hooksSettingsFlag)
        yoloArgs = try c.decodeIfPresent([String].self, forKey: .yoloArgs) ?? []
        modelFlag = try c.decodeIfPresent(String.self, forKey: .modelFlag)
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        effortArgs = try c.decodeIfPresent([String: [String]].self, forKey: .effortArgs) ?? [:]
        autoAnswers = try c.decodeIfPresent([AutoAnswer].self, forKey: .autoAnswers) ?? []
        resumeArgs = try c.decodeIfPresent([String].self, forKey: .resumeArgs) ?? []
        pluginDirFlag = try c.decodeIfPresent(String.self, forKey: .pluginDirFlag)
        contextFlag = try c.decodeIfPresent(String.self, forKey: .contextFlag)
        sessionIdFlag = try c.decodeIfPresent(String.self, forKey: .sessionIdFlag)
        resumeIdFlag = try c.decodeIfPresent(String.self, forKey: .resumeIdFlag)
    }

    public static let defaultWaiting = [
        #"(?i)\[y/n\]"#, #"(?i)\(y/n\)"#, #"(?i)do you want to"#, #"(?i)press enter"#,
        #"(?i)allow .* to"#, #"(?i)approve"#, #"❯ ?1\."#
    ]

    public var commandLine: [String] { [command] + args }

    /// Full argv for a launch with the chosen options.
    public func argv(yolo: Bool = false, model: String? = nil, effort: String? = nil, resume: Bool = false) -> [String] {
        var a = commandLine
        if yolo { a += yoloArgs }
        if let model, !model.isEmpty, let f = modelFlag { a += [f, model] }
        if let effort, let e = effortArgs[effort] { a += e }
        if resume { a += resumeArgs }
        return a
    }

    /// True when `argv` already names the conversation to continue.
    public func resumes(_ argv: [String]) -> Bool {
        resumeIdFlag.map(argv.contains) == true || (!resumeArgs.isEmpty && argv.contains(where: resumeArgs.contains))
    }

    /// `argv` changed to continue its conversation: the pinned id when there is one, else the agent's "latest here".
    public func resuming(_ argv: [String]) -> [String] {
        if let f = sessionIdFlag, let r = resumeIdFlag, let i = argv.firstIndex(of: f), i + 1 < argv.count {
            var a = argv; a[i] = r; return a
        }
        return resumes(argv) ? argv : argv + resumeArgs
    }

    static let trust = AutoAnswer(pattern: #"(?i)(do you trust|trust (the files|this folder|the contents)|one you trust|allow .* to work in this folder)"#, input: "\r",
                                  choose: #"(?i)(yes|trust|allow|proceed)"#)

    public static let presets: [AgentManifest] = [
        .init(id: "claude", name: "Claude Code", command: "claude", hooksSettingsFlag: "--settings",
              yoloArgs: ["--dangerously-skip-permissions"], modelFlag: "--model", models: ["opus", "sonnet", "haiku"],
              autoAnswers: [trust], resumeArgs: ["--continue"], pluginDirFlag: "--plugin-dir", contextFlag: "--append-system-prompt",
              sessionIdFlag: "--session-id", resumeIdFlag: "--resume"),
        .init(id: "codex", name: "Codex", command: "codex", yoloArgs: ["--dangerously-bypass-approvals-and-sandbox"],
              modelFlag: "-m", models: ["gpt-5-codex", "gpt-5"],
              effortArgs: ["low": ["-c", "model_reasoning_effort=low"], "medium": ["-c", "model_reasoning_effort=medium"], "high": ["-c", "model_reasoning_effort=high"]],
              autoAnswers: [trust], resumeArgs: ["resume", "--last"]),
        .init(id: "opencode", name: "OpenCode", command: "opencode", modelFlag: "-m", resumeArgs: ["--continue"]),
        .init(id: "gemini", name: "Gemini CLI", command: "gemini", yoloArgs: ["--yolo"], modelFlag: "-m", models: ["gemini-2.5-pro", "gemini-2.5-flash"], autoAnswers: [trust]),
        .init(id: "cursor", name: "Cursor Agent", command: "cursor-agent", yoloArgs: ["--force"], modelFlag: "--model", autoAnswers: [trust], resumeArgs: ["resume"]),
        .init(id: "pi", name: "Pi", command: "pi"),
        .init(id: "amp", name: "Amp", command: "amp", yoloArgs: ["--dangerously-allow-all"])
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

    /// Settings UI: save an override (binary, args, env…) or reset to the preset by deleting it.
    public static func saveOverride(_ m: AgentManifest, dir: URL = Paths.agents) throws {
        try Paths.ensure(dir)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(m).write(to: dir.appendingPathComponent("\(m.id).json"))
    }
    public static func resetOverride(id: String, dir: URL = Paths.agents) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }

    /// A "custom command" agent: any shell command.
    public static func custom(_ command: String) -> AgentManifest {
        .init(id: "custom", name: "Custom", command: "/bin/zsh", args: ["-lc", command])
    }
}

public enum Hooks {
    /// Claude-style settings file: Stop → done, Notification → waiting (`krill hook` drops the idle reminder),
    /// AskUserQuestion → waiting until answered. `krill` must be on PATH in the session.
    public static func settingsJSON() -> String {
        func hook(_ ev: String, _ matcher: String? = nil) -> String {
            #"[{\#(matcher.map { #""matcher":"\#($0)","# } ?? "")"hooks":[{"type":"command","command":"krill hook \#(ev)"}]}]"#
        }
        return #"{"hooks":{"Stop":\#(hook("done")),"Notification":\#(hook("waiting")),"UserPromptSubmit":\#(hook("working")),"#
            + #""PreToolUse":\#(hook("waiting", "AskUserQuestion")),"PostToolUse":\#(hook("working", "AskUserQuestion"))}}"#
    }

    /// Claude Code repeats "waiting for your input" a minute after a turn ends; that's a finished agent, not a question.
    public static func isIdleReminder(_ payload: JSONValue) -> Bool {
        payload["notification_type"]?.string == "idle_prompt"
            || payload["message"]?.string?.hasPrefix("Claude is waiting for your input") == true
    }

    public static func writeSettings(to url: URL) throws {
        try Paths.ensure(url.deletingLastPathComponent())
        try settingsJSON().write(to: url, atomically: true, encoding: .utf8)
    }
}
