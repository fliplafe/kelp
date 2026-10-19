import Foundation

public enum Paths {
    public static var root: URL {
        if let e = ProcessInfo.processInfo.environment["KRILL_HOME"] { return URL(fileURLWithPath: e) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".krill")
    }
    public static var socket: URL { root.appendingPathComponent("krill.sock") }
    public static var agents: URL { root.appendingPathComponent("agents") }
    public static var extensions: URL { root.appendingPathComponent("extensions") }
    /// Claude Code plugins with Krill's skills (one per skill that's turned on), loaded per session with --plugin-dir.
    public static var agentSkills: URL { root.appendingPathComponent("agent-skills") }
    /// A folder of its own for agents and terminals outside any project (Window › Scratch); not listed with the projects.
    public static var scratch: URL { root.appendingPathComponent("scratch") }

    public static func ensure(_ u: URL) throws {
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    }
}
