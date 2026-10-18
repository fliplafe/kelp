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
