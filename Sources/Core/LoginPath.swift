import Foundation

/// The PATH agents need. A daemon started from Finder only has /usr/bin:/bin, while agent CLIs live where the
/// user's shell profile points (~/.local/bin, Homebrew, npm…). Read once from a login shell, plus well-known dirs.
public enum LoginPath {
    public static let value: String = {
        // Given outright (tests: the user's shell profile must not run), it is the PATH.
        if let given = ProcessInfo.processInfo.environment["KELP_LOGIN_PATH"] { return given }
        let home = NSHomeDirectory()
        let known = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
                     "\(home)/.claude/local", "\(home)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let dirs = shellPath().split(separator: ":").map(String.init)
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + known.filter { FileManager.default.fileExists(atPath: $0) }
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }()

    /// Absolute path of `command`, or a message the UI can show as is.
    public static func resolve(_ command: String) throws -> String {
        if command.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: command) else { throw RPCError.invalidParams("\(command) doesn't exist or isn't executable.") }
            return command
        }
        for dir in value.split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(dir)/\(command)") {
            return "\(dir)/\(command)"
        }
        throw RPCError.invalidParams("Couldn't find `\(command)`. Install it, or make sure your shell profile adds it to PATH.")
    }

    /// `$SHELL -ilc` prints the PATH the user's terminal would have (interactive too: many put PATH in .zshrc).
    private static func shellPath() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-ilc", "printf '__KELP__%s__KELP__' \"$PATH\""]
        // A file, not a pipe: a profile that starts something in the background (nohup … &) keeps a pipe open forever, and
        // reading it to the end would never return; a file is read as it is once the shell has exited.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let out = try? FileHandle(forWritingTo: file) else { return "" }
        defer { try? out.close() }
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let deadline = Date().addingTimeInterval(8)   // a slow or prompting profile must not hold up agents
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return "" }
        let s = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard let a = s.range(of: "__KELP__"), let b = s.range(of: "__KELP__", range: a.upperBound..<s.endIndex) else { return "" }
        return String(s[a.upperBound..<b.lowerBound])
    }
}
