import AppKit
import SwiftUI
import Core
import Agents

/// Per-agent: its version (and a newer one, if published), Install / Update in a terminal you can watch, and overrides:
/// binary, arguments, environment. Secrets in the environment go to the login keychain. Reset deletes the override.
struct AgentsSettings: View {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    @State private var agents = AgentManifest.load()
    @State private var selection: String? = "claude"
    @State private var command = ""
    @State private var args = ""
    @State private var env = ""
    @State private var saved = false
    @State private var versions: [String: (version: String?, latest: String?)] = [:]

    private var updates: [AgentManifest] { agents.filter { newer(versions[$0.id]) } }
    /// "2.1.310" is newer than "2.1.304" (numbers, not text; a build ahead of npm isn't behind).
    private func newer(_ v: (version: String?, latest: String?)?) -> Bool {
        guard let a = v?.version, let b = v?.latest else { return false }
        return a.compare(b, options: .numeric) == .orderedAscending
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // What's on this Mac first; the rest under it, greyed, to install from the right side.
                List(selection: $selection) {
                    let installed = agents.filter { versions[$0.id]?.version != nil }
                    if versions.isEmpty { ForEach(agents, id: \.id) { row($0) } } else {
                        Section("Installed") { ForEach(installed, id: \.id) { row($0) } }
                        Section("Not Installed") { ForEach(agents.filter { a in !installed.contains { $0.id == a.id } }, id: \.id) { row($0) } }
                    }
                }
                if !updates.isEmpty {
                    Text(updates.count == 1 ? String(localized: "1 update available") : String(localized: "\(updates.count) updates available"))
                        .font(.caption).foregroundStyle(.orange).padding(8)
                }
            }
            .frame(width: 190)
            Form {
                if let m = current { versionRow(m) }
                TextField("Command", text: $command)
                TextField("Arguments", text: $args, prompt: Text("space separated"))
                TextField("Environment", text: $env, prompt: Text("KEY=value, one per line"), axis: .vertical).lineLimit(3...6)
                if let m = current, !Self.presets(m.id).isEmpty {
                    Menu("Provider Presets") {
                        ForEach(Self.presets(m.id), id: \.0) { name, lines in Button(name) { addLines(lines) } }
                    }.fixedSize()
                }
                HStack {
                    Button("Reset to Default") { if let id = selection { AgentManifest.resetOverride(id: id); reload() } }
                    Spacer()
                    if saved { Text("Saved").foregroundStyle(.secondary) }
                    Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction)
                }
                Text("Values of *_KEY, *_TOKEN and *_SECRET are kept in your login keychain, not in the agent's file. Agents are JSON files in ~/.kelp/agents — add a file to add any CLI agent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.columns)   // already inside Settings' grouped section: a second card in it would nest boxes
            .padding(.leading, 16)
        }
        .onChange(of: selection) { _, _ in load() }
        .onAppear { load() }
        .task { await loadVersions() }
    }

    private func row(_ a: AgentManifest) -> some View {
        let version = versions[a.id]?.version
        return HStack(spacing: 8) {
            Image(nsImage: AgentCatalog.icon(a.id, size: 18) ?? NSImage()).resizable().frame(width: 18, height: 18)
                .opacity(version == nil && !versions.isEmpty ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(a.name).foregroundStyle(version == nil && !versions.isEmpty ? .secondary : .primary)
                    if updates.contains(where: { $0.id == a.id }) { Circle().fill(.orange).frame(width: 6, height: 6).help("Update available") }
                }
                Text(version.map { "\($0) · \(a.command)" } ?? (versions.isEmpty ? " " : String(localized: "Not installed"))).font(.caption).foregroundStyle(.secondary)
            }
        }.tag(Optional(a.id))
    }

    @ViewBuilder private func versionRow(_ m: AgentManifest) -> some View {
        let v = versions[m.id]
        HStack {
            if let installed = v?.version {
                Text("Version \(installed)") + Text(newer(v) ? String(localized: " · \(v?.latest ?? "") available") : "").foregroundColor(.orange)
            } else { Text(versions.isEmpty ? String(localized: "Checking…") : String(localized: "Not installed")).foregroundStyle(.secondary) }
            Spacer()
            if v?.version == nil, let cmd = m.install { Button("Install…") { run(cmd, String(localized: "Install \(m.name)")) }.help(cmd) }
            else if let cmd = m.update {
                Button(newer(v) ? String(localized: "Update") : String(localized: "Check for Update")) { run(cmd, String(localized: "Update \(m.name)")) }.help(cmd)
            }
        }
        // The agents of SSH projects run on their hosts: the same command there, one terminal per host.
        if let cmd = m.update, !hosts.isEmpty {
            HStack {
                let names = hosts.map(\.host).joined(separator: ", ")
                Text("SSH hosts: \(names)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(names)
                Spacer()
                Button("Update on Hosts") { for h in hosts { run(cmd, String(localized: "Update \(m.name) on \(h.host)"), in: h.folder) } }.help(cmd)
            }
        }
    }

    /// One remote project's folder per host: a command run in it runs on that host, in its login shell.
    private var hosts: [(host: String, folder: String)] {
        var seen = Set<String>()
        return app.repos.compactMap { r in RemoteHost.of(r.path).flatMap { seen.insert($0.host).inserted ? ($0.host, r.path) : nil } }
    }

    /// The agent's own command, in a terminal in the workspace on screen, so what it does is in plain sight.
    private func run(_ cmd: String, _ title: String, in folder: String? = nil) {
        guard let e = Workbench.editor else {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
            Banner.show(String(localized: "Open a workspace to run it there — the command is on the clipboard: \(cmd)")); return
        }
        e.run(command: cmd, title: title, cwd: folder)
        Workbench.window?.window?.makeKeyAndOrderFront(nil)
    }

    private func loadVersions() async {
        // Quiet: a version column beside each agent (npm offline, say); unknown versions just stay blank.
        let rows = await app.quiet(AgentsVersions(), timeout: 60) ?? []
        var v: [String: (String?, String?)] = [:]
        for r in rows { v[r.id] = (r.version, r.latest) }
        for a in agents where v[a.id] == nil { v[a.id] = (nil, nil) }
        versions = v
    }

    /// Ways to run an agent through another provider, as environment variables its docs define.
    static func presets(_ agent: String) -> [(String, [String])] {
        switch agent {
        case "claude": [
            ("Anthropic API Key", ["ANTHROPIC_API_KEY="]),
            ("Amazon Bedrock", ["CLAUDE_CODE_USE_BEDROCK=1", "AWS_REGION=us-east-1", "AWS_PROFILE=default"]),
            ("Google Vertex AI", ["CLAUDE_CODE_USE_VERTEX=1", "CLOUD_ML_REGION=us-east5", "ANTHROPIC_VERTEX_PROJECT_ID="]),
            ("Gateway (LiteLLM, Ollama…)", ["ANTHROPIC_BASE_URL=http://localhost:4000", "ANTHROPIC_AUTH_TOKEN="])
        ]
        case "codex": [("OpenAI API Key", ["OPENAI_API_KEY="]), ("OpenAI-compatible Endpoint (OpenRouter…)", ["OPENAI_BASE_URL=https://openrouter.ai/api/v1", "OPENAI_API_KEY="])]
        case "gemini": [("Gemini API Key", ["GEMINI_API_KEY="]),
                        ("Google Vertex AI", ["GOOGLE_GENAI_USE_VERTEXAI=true", "GOOGLE_CLOUD_PROJECT=", "GOOGLE_CLOUD_LOCATION=us-central1"])]
        default: []
        }
    }
    private func addLines(_ lines: [String]) {
        var have = env.split(separator: "\n").map(String.init)
        for l in lines where !have.contains(where: { $0.hasPrefix(l.split(separator: "=").first.map { $0 + "=" } ?? l) }) { have.append(l) }
        env = have.joined(separator: "\n")
    }

    private var current: AgentManifest? { agents.first { $0.id == selection } }
    private func load() {
        guard let m = current else { return }
        command = m.command; args = m.args.joined(separator: " ")
        env = m.env.map { "\($0)=\($1)" }.sorted().joined(separator: "\n"); saved = false
    }
    private func reload() { agents = AgentManifest.load(); load() }
    /// "Saved" only once it is: a secret the keychain refused, or a file that couldn't be written, says why instead.
    private func save() async {
        guard var m = current else { return }
        m.command = command; m.args = args.split(separator: " ").map(String.init)
        var pairs = Dictionary(env.split(separator: "\n").compactMap { l -> (String, String)? in
            let p = l.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return p.count == 2 ? (String(p[0]).trimmingCharacters(in: .whitespaces), String(p[1])) : nil
        }, uniquingKeysWith: { $1 })
        // Secrets: the daemon puts them in the keychain; the file only says where they are.
        for (k, v) in pairs where AgentManifest.isSecret(k) && v != AgentManifest.keychainValue && !v.isEmpty {
            guard await app.call(AgentSetSecret(agent: m.id, key: k, value: v)) != nil else { return }
            pairs[k] = AgentManifest.keychainValue
        }
        for k in m.env.keys where pairs[k] == nil && m.env[k] == AgentManifest.keychainValue {
            await app.call(AgentSetSecret(agent: m.id, key: k))   // removed: forget it
        }
        m.env = pairs.filter { !$0.value.isEmpty }   // a preset's blank line until it's filled in
        do { try AgentManifest.saveOverride(m) } catch {
            Banner.show(String(localized: "Couldn't save \(m.name): \(error.localizedDescription)"), style: .error); return
        }
        reload(); saved = true
        app.agents = AgentManifest.load()
        AgentAvailability.shared.refresh(force: true)
    }
}
