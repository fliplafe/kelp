import AppKit
import SwiftUI
import Core

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
    static var cached: [AccountProfile] = []
    static func load() async -> [AccountProfile] {
        let v = await AppModel.shared.call("config.get")
        cached = (try? v?["profiles"]?.decode([AccountProfile].self)) ?? []
        return cached
    }
    static func save(_ list: [AccountProfile]) async {
        cached = list
        await AppModel.shared.call("config.set", .obj(["profiles": (try? JSONValue.from(list)) ?? .array([])]))
    }
    static func profiles(for agent: String) -> [AccountProfile] { cached.filter { $0.agent == agent } }
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
        guard let p = profiles.first(where: { $0.id == selection }), let d = NSApp.delegate as? AppDelegate, let wid = d.content.worktreeId else { NSSound.beep(); return }
        Task {
            guard let r = await AppModel.shared.call("session.create", .obj(["worktreeId": .string(wid), "agent": .string(p.agent), "profile": .string(p.name), "title": .string("Log in: \(p.name)")])),
                  let s = try? r.decode(Session.self) else { return }
            d.content.workspace?.add(session: s)
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
