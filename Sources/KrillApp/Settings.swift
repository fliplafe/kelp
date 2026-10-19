import AppKit
import SwiftUI
import Core
import Agents
import LocalAI

/// Per-agent overrides: binary, arguments, environment. Reset deletes the override.
struct AgentsSettings: View {
    @State private var agents = AgentManifest.load()
    @State private var selection: String? = "claude"
    @State private var command = ""
    @State private var args = ""
    @State private var env = ""
    @State private var saved = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            List(agents, id: \.id, selection: $selection) { Text($0.name).tag(Optional($0.id)) }
                .frame(width: 170)
            Form {
                TextField("Command", text: $command)
                TextField("Arguments", text: $args, prompt: Text("space separated"))
                TextField("Environment", text: $env, prompt: Text("KEY=value, one per line"), axis: .vertical).lineLimit(3...6)
                HStack {
                    Button("Reset to Default") { if let id = selection { AgentManifest.resetOverride(id: id); reload() } }
                    Spacer()
                    if saved { Text("Saved").foregroundStyle(.secondary) }
                    Button("Save") { save() }.keyboardShortcut(.defaultAction)
                }
                Text("Agents are JSON files in ~/.krill/agents — add a file to add any CLI agent.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
        .onChange(of: selection) { _, _ in load() }
        .onAppear { load() }
    }

    private var current: AgentManifest? { agents.first { $0.id == selection } }
    private func load() {
        guard let m = current else { return }
        command = m.command; args = m.args.joined(separator: " ")
        env = m.env.map { "\($0)=\($1)" }.sorted().joined(separator: "\n"); saved = false
    }
    private func reload() { agents = AgentManifest.load(); load() }
    private func save() {
        guard var m = current else { return }
        m.command = command; m.args = args.split(separator: " ").map(String.init)
        m.env = Dictionary(env.split(separator: "\n").compactMap { l -> (String, String)? in
            let p = l.split(separator: "=", maxSplits: 1); return p.count == 2 ? (String(p[0]).trimmingCharacters(in: .whitespaces), String(p[1])) : nil
        }, uniquingKeysWith: { $1 })
        try? AgentManifest.saveOverride(m); reload(); saved = true
        AppModel.shared.agents = AgentManifest.load()
        AgentAvailability.shared.refresh(force: true)
    }
}
