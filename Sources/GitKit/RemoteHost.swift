import Foundation
import os
import Core

/// A project on another machine, over SSH. Kelp keeps a local folder for it that holds only `.kelp-remote`
/// (`{"host", "path"}`); git in that folder runs on the host instead (so the git and file panels work as they are),
/// and so do its agents and terminals. All of it shares one SSH connection per host (ControlMaster), kept for ten
/// minutes after the last use; a dropped connection ends the sessions, and Restart connects again.
public struct RemoteHost: Codable, Sendable, Equatable {
    public var host: String, path: String
    public init(host: String, path: String) { self.host = host; self.path = path }

    public static let marker = ".kelp-remote"
    /// Where the shared connections' sockets live; the daemon points it at KELP_HOME/ssh once, at start.
    /// Under a lock: every `Daemon` sets it when it starts, and tests start several at once (a String written from two
    /// threads at the same time corrupts memory).
    public static var controlDir: String {
        get { controlPath.withLock { $0 } }
        set { controlPath.withLock { $0 = newValue } }
    }
    private static let controlPath = OSAllocatedUnfairLock(initialState: NSTemporaryDirectory())
    /// `ssh` (tests use a stand-in that runs the command locally).
    public static let ssh = ProcessInfo.processInfo.environment["KELP_SSH"] ?? "/usr/bin/ssh"

    /// Where Kelp keeps remote projects' folders (`<KELP_HOME>/remote`). A `.kelp-remote` anywhere else — say, committed
    /// to a repository someone clones — is just a file: it must not send that project's git, agents and terminals to
    /// a host it names.
    private static let trusted = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    public static func trust(_ dir: URL) { trusted.withLock { _ = $0.insert(dir.standardizedFileURL.path) } }

    /// The remote a project folder stands for (its own folder only: a workspace is that folder).
    public static func of(_ dir: String) -> RemoteHost? {
        let path = URL(fileURLWithPath: dir).standardizedFileURL.path
        let roots = trusted.withLock { $0 }.union([Paths.root.appendingPathComponent("remote").standardizedFileURL.path])
        guard roots.contains(where: { path.hasPrefix($0 + "/") }), let d = FileManager.default.contents(atPath: path + "/" + marker),
              let r = try? JSONDecoder().decode(RemoteHost.self, from: d), Self.isHost(r.host) else { return nil }
        return r
    }

    /// What may follow `ssh`: not an option, nothing a shell would split.
    /// Also a folder name under remote/: "." / ".." or a "/" would put it somewhere else.
    public static func isHost(_ h: String) -> Bool {
        !h.isEmpty && !h.hasPrefix("-") && !h.contains(where: \.isWhitespace) && !h.contains("/") && h != "." && h != ".."
    }

    /// For a path inside a remote project's folder: the folder, its remote, and the path on the host.
    public static func containing(_ path: String) -> (folder: String, remote: RemoteHost, remotePath: String)? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path   // "x/../../y" can't reach past the project
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
            + ["-o", "ConnectTimeout=15", "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(Self.controlDir)/%C", "-o", "ControlPersist=600", "-o", "ServerAliveInterval=30", "--", host]
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
    public static func quote(_ s: String) -> String { IDE.shellWord(s) }
}
