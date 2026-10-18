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
    @State private var hibernate = 0

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
            Picker("Pause idle agents after", selection: $hibernate) {
                Text("Never").tag(0); Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("1 hour").tag(60); Text("3 hours").tag(180)
            }
            .onChange(of: hibernate) { _, v in Task { await AppModel.shared.call("config.set", .obj(["hibernateMinutes": .int(v)])) } }
            Text("Paused agents free their memory and resume the same conversation when you open them (Claude Code, Codex, OpenCode, Cursor).")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("On-device model for titles, branch names, summaries and drafts", isOn: $localAI)
            Text(LocalAI.isAvailable || !localAI ? "Runs locally with Apple Intelligence. Nothing leaves your Mac." : "Apple Intelligence is not available on this Mac; Krill uses simple fallbacks.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Language servers (errors, jump to definition, completion)", isOn: $lsp)
        }
        .formStyle(.grouped)
        .task {
            let c = await AppModel.shared.call("config.get")
            keepAwake = c?["keepAwake"]?.string ?? "agents"; hibernate = c?["hibernateMinutes"]?.int ?? 0
        }
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

/// Standard macOS preferences window: toolbar tabs with SF Symbols, each pane a SwiftUI form.
@MainActor
enum SettingsWindow {
    static var window: NSWindow?
    /// Later features can add panes here.
    static var extraTabs: [(String, String, AnyView)] = []

    static func show() {
        if window == nil {
            let tabs = NSTabViewController(); tabs.tabStyle = .toolbar
            func add(_ title: String, _ symbol: String, _ view: some View) {
                let host = NSHostingController(rootView: view.frame(width: 640).fixedSize(horizontal: false, vertical: true))
                host.sizingOptions = [.preferredContentSize]   // the window resizes to each pane, like System Settings
                let item = NSTabViewItem(viewController: host); item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            add("General", "gearshape", GeneralSettings())
            add("Agents", "cpu", AgentsSettings().frame(height: 380))
            add("Accounts", "person.2", AccountsSettings().frame(height: 340))
            add("Integrations", "link", IntegrationsSettings())
            add("Commands", "bolt", QuickCommandsSettings().frame(height: 340))
            add("Appearance", "paintpalette", AppearanceSettings())
            for t in extraTabs { add(t.0, t.1, t.2) }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false; w.title = "Settings"
            window = w
        }
        window?.center(); window?.makeKeyAndOrderFront(nil)
    }
}

struct QuickCommandsSettings: View {
    @State private var items: [QuickCommand] = []
    @State private var name = ""
    @State private var text = ""
    @State private var newTab = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List { ForEach(items, id: \.self) { q in HStack { Text(q.name).bold(); Text(q.text).foregroundStyle(.secondary).lineLimit(1); Spacer(); if q.newTab { Text("new tab").font(.caption) } } }
                .onDelete { items.remove(atOffsets: $0); QuickCommands.global = items } }
            HStack {
                TextField("Name", text: $name).frame(width: 140)
                TextField("Prompt or shell command", text: $text)
                Toggle("Run in new tab", isOn: $newTab)
                Button("Add") { guard !name.isEmpty, !text.isEmpty else { return }; items.append(QuickCommand(name: name, text: text, newTab: newTab)); QuickCommands.global = items; name = ""; text = "" }
            }
            Text("Run from the Command Palette (⇧⌘P). Per-project commands: `command.<name>: text` in .krill.yaml.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear { items = QuickCommands.global }
    }
}
