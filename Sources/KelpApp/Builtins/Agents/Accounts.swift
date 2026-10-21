import AppKit
import SwiftUI
import Core
import WorkbenchKit

/// Account profiles for Claude Code / Codex: each has its own config dir (CLAUDE_CONFIG_DIR / CODEX_HOME),
/// so logins stay side by side and switching is just a different environment.
struct AccountProfile: Codable, Hashable, Identifiable {
    var name: String; var agent: String; var dir: String
    var id: String { agent + "/" + name }
    static func defaultDir(agent: String, name: String) -> String {
        Paths.root.appendingPathComponent("accounts/\(agent)/\(name)").path
    }
}

@MainActor
enum Accounts {
    static func load() async -> [AccountProfile] {
        let saved = await AppModel.shared.call(SettingsGet())?["accounts.profiles"]   // a banner when the settings can't be read
        return (try? saved?.decode([AccountProfile].self)) ?? []
    }
    static func save(_ list: [AccountProfile]) async {
        await AppModel.shared.call(SettingsSet(key: "accounts.profiles", value: (try? JSONValue.from(list)) ?? .array([])))
    }
}

struct AccountsSettings: View {
    @State private var profiles: [AccountProfile] = []
    @State private var selection: AccountProfile.ID?
    @State private var newName = ""
    @State private var newAgent = "claude"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(profiles, selection: $selection) {
                TableColumn("Name", value: \.name)
                TableColumn("Agent", value: \.agent).width(80)
                TableColumn("Config folder", value: \.dir)
            }
            HStack {
                Picker("", selection: $newAgent) { Text("Claude Code").tag("claude"); Text("Codex").tag("codex") }.labelsHidden().frame(width: 130)
                TextField("Profile name (e.g. work)", text: $newName).frame(width: 200)
                Button("Add") {
                    let n = newName.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
                    profiles.append(AccountProfile(name: n, agent: newAgent, dir: AccountProfile.defaultDir(agent: newAgent, name: n)))
                    newName = ""; Task { await Accounts.save(profiles) }
                }
                Spacer()
                Button("Log In…") { login() }.disabled(selection == nil)
                Button("Remove") { profiles.removeAll { $0.id == selection }; Task { await Accounts.save(profiles) } }.disabled(selection == nil)
            }
            Text("Log in once per profile; afterwards pick the account when starting an agent. Usage and limits per account show in Agents › Usage.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .task { profiles = await Accounts.load() }
    }

    /// Opens the agent in that profile so the user can run its login flow once.
    private func login() {
        guard let p = profiles.first(where: { $0.id == selection }), let wid = Workbench.shared.workspaceId else { NSSound.beep(); return }
        Task {
            guard let s = await AppModel.shared.call(SessionCreate(worktreeId: wid, agent: p.agent, title: String(localized: "Log in: \(p.name)"),
                                                                   profile: p.name)) else { return }
            AppModel.shared.upsert(s); Workbench.open(TabURI.session(s.id))
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
