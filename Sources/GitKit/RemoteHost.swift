import Foundation

/// A project on another machine, over SSH. Krill keeps a local folder for it that holds only `.krill-remote`
/// (`{"host", "path"}`); git in that folder runs on the host instead (so the git and file panels work as they are),
/// and so do its agents and terminals. All of it shares one SSH connection per host (ControlMaster), kept for ten
/// minutes after the last use; a dropped connection ends the sessions, and Restart connects again.
public struct RemoteHost: Codable, Sendable, Equatable {
    public var host: String, path: String
    public init(host: String, path: String) { self.host = host; self.path = path }

    public static let marker = ".krill-remote"
    /// Where the shared connections' sockets live; the daemon points it at KRILL_HOME/ssh once, at start.
    nonisolated(unsafe) public static var controlDir = NSTemporaryDirectory()
    /// `ssh` (tests use a stand-in that runs the command locally).
    public static let ssh = ProcessInfo.processInfo.environment["KRILL_SSH"] ?? "/usr/bin/ssh"

    /// The remote a project folder stands for (its own folder only: a workspace is that folder).
    public static func of(_ dir: String) -> RemoteHost? {
        guard let d = FileManager.default.contents(atPath: dir + "/" + marker) else { return nil }
        return try? JSONDecoder().decode(RemoteHost.self, from: d)
    }

    /// For a path inside a remote project's folder: the folder, its remote, and the path on the host.
    public static func containing(_ path: String) -> (folder: String, remote: RemoteHost, remotePath: String)? {
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if let r = of(dir) { return (dir, r, r.path + String(path.dropFirst(dir.count))) }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// ssh's options for this host: the shared connection; no password prompts where nobody can answer them.
    public func sshArgs(tty: Bool) -> [String] {
        (tty ? ["-tt"] : ["-T", "-o", "BatchMode=yes"])
            + ["-o", "ControlMaster=auto", "-o", "ControlPath=\(Self.controlDir)/%C", "-o", "ControlPersist=600", "-o", "ServerAliveInterval=30", host]
    }

    /// What the host's shell runs: `argv` in the project's folder, through a login shell so the host's PATH applies;
    /// nil argv is an interactive login shell.
    public func command(_ argv: [String]?) -> String {
        let cd = "cd \(Self.cdArg(path))"
        guard let argv, !argv.isEmpty else { return cd + " && exec \"$SHELL\" -l" }
        // A local absolute path means nothing there: the host finds the program by name.
        let words = [(argv[0] as NSString).lastPathComponent] + argv.dropFirst()
        return cd + " && exec \"$SHELL\" -lc " + Self.quote(words.map(Self.quote).joined(separator: " "))
    }

    /// `cd`'s argument: quoted, with a leading ~ left outside the quotes so the host's shell expands it.
    public static func cdArg(_ path: String) -> String {
        path == "~" ? "~" : path.hasPrefix("~/") ? "~/" + quote(String(path.dropFirst(2))) : quote(path)
    }

    /// One shell word, single-quoted.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
