import Foundation

public enum Paths {
    public static var root: URL {
        if let e = ProcessInfo.processInfo.environment["KRILL_HOME"] { return URL(fileURLWithPath: e) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".krill")
    }
    public static var socket: URL { root.appendingPathComponent("krill.sock") }
    public static var database: URL { root.appendingPathComponent("krill.sqlite") }
    public static var history: URL { root.appendingPathComponent("history") }
    public static var worktrees: URL { root.appendingPathComponent("worktrees") }
    public static var agents: URL { root.appendingPathComponent("agents") }

    public static func ensure(_ u: URL) throws {
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    }
}
