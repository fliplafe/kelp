import Foundation
import Agents

/// Which agent CLIs are actually installed, so the UI offers what will run.
enum AgentCatalog {
    static let searchPath: [String] = {
        let home = NSHomeDirectory()
        let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return env + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
                      "\(home)/.claude/local", "\(home)/.cargo/bin", "/usr/bin"]
    }()

    static func isInstalled(_ m: AgentManifest) -> Bool {
        if m.command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: m.command) }
        return searchPath.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(m.command)") }
    }

    static func installed(_ all: [AgentManifest]) -> [AgentManifest] { all.filter(isInstalled) }

    /// Built-in and user agent manifests plus agents contributed by extensions.
    @MainActor static var all: [AgentManifest] {
        let base = AppModel.shared.agents
        return base + ExtensionRegistry.shared.all.agents.filter { a in !base.contains { $0.id == a.id } }
    }
    /// The agent "New Agent" starts: the setting if it's installed, else the first installed one.
    @MainActor static var defaultAgent: String {
        let installed = installed(all)
        if let d = SettingsStore.shared.string("agents.default"), installed.contains(where: { $0.id == d }) { return d }
        return installed.first?.id ?? "claude"
    }
    @MainActor static func name(_ id: String?) -> String {
        guard let id else { return "Terminal" }
        if id == "shell" { return "Terminal" }
        return all.first { $0.id == id }?.name ?? id.capitalized
    }

    static func symbol(_ id: String?) -> String {
        switch id {
        case "claude": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "gemini": "star.circle"
        case "opencode": "curlybraces"
        case "cursor": "cursorarrow.rays"
        case "amp": "bolt"
        case "shell", nil: "terminal"
        case "custom": "apple.terminal"
        default: "cpu"
        }
    }
}
