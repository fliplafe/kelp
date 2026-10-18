import AppKit
import SwiftUI
import Core
import Agents
import LocalAI

struct GeneralSettings: View {
    @AppStorage("defaultAgent") private var defaultAgent = "claude"
    @AppStorage("permissionMode") private var permissionMode = "manual"
    @AppStorage("branchPrefix") private var branchPrefix = ""
    @AppStorage("localAIEnabled") private var localAI = true
    @AppStorage("lspEnabled") private var lsp = true
    @State private var keepAwake = "agents"

    var body: some View {
        Form {
            Picker("Default agent", selection: $defaultAgent) {
                ForEach(AgentManifest.load(), id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Permissions", selection: $permissionMode) {
                Text("Ask before actions").tag("manual"); Text("Yolo (skip approvals)").tag("yolo")
            }
            TextField("Branch prefix", text: $branchPrefix, prompt: Text("e.g. niko/"))
            Picker("Keep Mac awake", selection: $keepAwake) {
                Text("While agents work").tag("agents"); Text("Always").tag("always"); Text("Never").tag("off")
            }
            .onChange(of: keepAwake) { _, v in Task { await AppModel.shared.call("config.set", .obj(["keepAwake": .string(v)])) } }
            Toggle("On-device model for titles, branch names, summaries and drafts", isOn: $localAI)
            Text(LocalAI.isAvailable || !localAI ? "Runs locally with Apple Intelligence. Nothing leaves your Mac." : "Apple Intelligence is not available on this Mac; Krill uses simple fallbacks.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Language servers (errors, jump to definition, completion)", isOn: $lsp)
        }
        .formStyle(.grouped)
        .task { keepAwake = (await AppModel.shared.call("config.get"))?["keepAwake"]?.string ?? "agents" }
    }
}

/// Per-agent overrides: binary, arguments, Yolo flags, environment. Reset deletes the override.
struct AgentsSettings: View {
    @State private var agents = AgentManifest.load()
    @State private var selection: String? = "claude"
    @State private var command = ""
    @State private var args = ""
    @State private var yolo = ""
    @State private var env = ""
    @State private var saved = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            List(agents, id: \.id, selection: $selection) { Text($0.name).tag(Optional($0.id)) }
                .frame(width: 170)
            Form {
                TextField("Command", text: $command)
                TextField("Arguments", text: $args, prompt: Text("space separated"))
                TextField("Yolo arguments", text: $yolo)
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
        command = m.command; args = m.args.joined(separator: " "); yolo = m.yoloArgs.joined(separator: " ")
        env = m.env.map { "\($0)=\($1)" }.sorted().joined(separator: "\n"); saved = false
    }
    private func reload() { agents = AgentManifest.load(); load() }
    private func save() {
        guard var m = current else { return }
        m.command = command; m.args = args.split(separator: " ").map(String.init); m.yoloArgs = yolo.split(separator: " ").map(String.init)
        m.env = Dictionary(env.split(separator: "\n").compactMap { l -> (String, String)? in
            let p = l.split(separator: "=", maxSplits: 1); return p.count == 2 ? (String(p[0]).trimmingCharacters(in: .whitespaces), String(p[1])) : nil
        }, uniquingKeysWith: { $1 })
        try? AgentManifest.saveOverride(m); reload(); saved = true
        AppModel.shared.agents = AgentManifest.load()
    }
}

struct AppearanceSettings: View {
    @AppStorage("terminalFont") private var font = ""
    @AppStorage("terminalFontSize") private var size = 13.0
    @AppStorage("ghosttyTheme") private var useGhostty = true
    var body: some View {
        Form {
            TextField("Terminal font", text: $font, prompt: Text("System monospaced"))
            Stepper("Font size: \(Int(size)) pt", value: $size, in: 8...32)
            Toggle("Use colors and font from Ghostty config", isOn: $useGhostty)
            Text("Reads ~/.config/ghostty/config (background, foreground, font-family, font-size).").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Keyboard shortcuts") {
                Button("Customize in System Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!)
                }
            }
            Text("Any menu command can be rebound under Keyboard › Keyboard Shortcuts › App Shortcuts.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct SettingsView: View {
    var extraTabs: [(String, String, AnyView)] = SettingsWindow.extraTabs
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AgentsSettings().tabItem { Label("Agents", systemImage: "cpu") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            ForEach(extraTabs, id: \.0) { t in t.2.tabItem { Label(t.0, systemImage: t.1) } }
        }
        .frame(width: 620, height: 420)
    }
}

@MainActor
enum SettingsWindow {
    static var window: NSWindow?
    /// Later features (Accounts, Integrations) add tabs here.
    static var extraTabs: [(String, String, AnyView)] = []
    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Settings"; w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false; window = w
        }
        window?.center(); window?.makeKeyAndOrderFront(nil)
    }
}
