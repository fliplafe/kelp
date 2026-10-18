import Foundation

public struct GitError: Error, CustomStringConvertible, Sendable {
    public var args: [String]; public var status: Int32; public var stderr: String
    public var description: String { "git \(args.joined(separator: " ")) failed (\(status)): \(stderr)" }
}

/// Thin wrapper over the system git. Behaviour matches what you'd see in a terminal.
public enum Git {
    @discardableResult
    public static func run(_ args: [String], cwd: String, stdin: String? = nil, executable: String = "/usr/bin/git", ok: Set<Int32> = [0]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"; env["LC_ALL"] = "C"
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err
        if stdin != nil { p.standardInput = inp }
        try p.run()
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)); try? inp.fileHandleForWriting.close() }
        // Drain both pipes concurrently to avoid deadlock on large output.
        nonisolated(unsafe) var errData = Data()
        let g = DispatchGroup(); g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait(); p.waitUntilExit()
        guard ok.contains(p.terminationStatus) else {
            throw GitError(args: args, status: p.terminationStatus, stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: outData, as: UTF8.self)
    }

    public static func root(of path: String) throws -> String {
        try run(["rev-parse", "--show-toplevel"], cwd: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Default branch: origin/HEAD if set, else current branch of the main checkout.
    public static func defaultBranch(repo: String) -> String {
        if let s = try? run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: repo) {
            return String(s.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 != "/" }).dropFirst())
        }
        for b in ["main", "master"] where (try? run(["rev-parse", "--verify", b], cwd: repo)) != nil { return b }
        return (try? currentBranch(repo)) ?? "main"
    }

    public static func currentBranch(_ path: String) throws -> String {
        try run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
