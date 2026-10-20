import Foundation

public enum Paths {
    public static var root: URL {
        if let e = ProcessInfo.processInfo.environment["KELP_HOME"] { return URL(fileURLWithPath: e) }
        _ = movedFromKrill
        return home.appendingPathComponent(".kelp")
    }
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// The app was called Krill until 2026-10: the first run moves ~/.krill over, database included.
    private static let movedFromKrill: Void = {
        let fm = FileManager.default, old = home.appendingPathComponent(".krill"), new = home.appendingPathComponent(".kelp")
        guard !fm.fileExists(atPath: new.path), (try? fm.moveItem(at: old, to: new)) != nil else { return }
        for s in ["", "-wal", "-shm"] {
            try? fm.moveItem(at: new.appendingPathComponent("krill.sqlite" + s), to: new.appendingPathComponent("kelp.sqlite" + s))
        }
        try? fm.removeItem(at: new.appendingPathComponent("krill.sock"))
    }()
    public static var socket: URL { root.appendingPathComponent("kelp.sock") }
    public static var agents: URL { root.appendingPathComponent("agents") }
    public static var extensions: URL { root.appendingPathComponent("extensions") }
    /// Claude Code plugins with Kelp's skills (one per skill that's turned on), loaded per session with --plugin-dir.
    public static var agentSkills: URL { root.appendingPathComponent("agent-skills") }
    /// A folder of its own for agents and terminals outside any project (Window › Scratch); not listed with the projects.
    public static var scratch: URL { root.appendingPathComponent("scratch") }

    public static func ensure(_ u: URL) throws {
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    }
}
