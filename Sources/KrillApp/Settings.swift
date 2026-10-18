import AppKit
import SwiftUI
import Agents

struct SettingsView: View {
    @AppStorage("defaultAgent") private var defaultAgent = "claude"
    @AppStorage("terminalFont") private var font = "SF Mono"
    @AppStorage("terminalFontSize") private var size = 13.0
    @AppStorage("ghosttyTheme") private var useGhostty = true
    var body: some View {
        Form {
            Picker("Default agent", selection: $defaultAgent) {
                ForEach(AgentManifest.load(), id: \.id) { Text($0.name).tag($0.id) }
            }
            TextField("Terminal font", text: $font)
            Stepper("Font size: \(Int(size))", value: $size, in: 8...32)
            Toggle("Use Ghostty config for colors", isOn: $useGhostty)
            Text("Agents live in ~/.krill/agents/*.json").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 440)
    }
}

@MainActor
enum SettingsWindow {
    static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Settings"; w.styleMask = [.titled, .closable]; window = w
        }
        window?.center(); window?.makeKeyAndOrderFront(nil)
    }
}
