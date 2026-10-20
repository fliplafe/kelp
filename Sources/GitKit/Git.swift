import Foundation

public struct GitError: Error, CustomStringConvertible, Sendable {
    public var args: [String]; public var status: Int32; public var stderr: String
    public var description: String { "git \(args.joined(separator: " ")) failed (\(status)): \(stderr)" }
    /// For people: git's first sentence without the command line or "fatal:" ("…overwritten by checkout:" keeps its next line).
    public var message: String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var first = lines.first else { return description }
        for p in ["fatal: ", "error: "] where first.hasPrefix(p) { first.removeFirst(p.count) }
        if first.hasSuffix(":"), lines.count > 1 { first += " " + lines[1] }
        return first.prefix(1).uppercased() + first.dropFirst()
    }
}

/// Thin wrapper over the system git. Behaviour matches what you'd see in a terminal.
public enum Git {
    @discardableResult
    public static func run(_ args: [String], cwd: String, stdin: String? = nil, executable: String = "/usr/bin/git", ok: Set<Int32> = [0],
                           env extra: [String: String] = [:]) throws -> String {
        String(decoding: try runData(args, cwd: cwd, stdin: stdin.map { Data($0.utf8) }, executable: executable, ok: ok, env: extra), as: UTF8.self)
    }

    /// `run`, its output as the bytes git wrote (a diff of a file that isn't UTF-8 goes back to `git apply` unchanged).
    @discardableResult
    public static func runData(_ args: [String], cwd: String, stdin: Data? = nil, executable: String = "/usr/bin/git", ok: Set<Int32> = [0],
                               env extra: [String: String] = [:], timeLimit: TimeInterval = 300) throws -> Data {
        // timeLimit: longest a git / gh / ssh run may take before it's stopped (it then fails like any other error). Five
        // minutes: far past any real fetch or push, short of a thread lost for good.
        var args = args, executable = executable, cwd = cwd
        if executable == "/usr/bin/git" {
            args = ["-c", "core.quotePath=false"] + args   // paths as they are, not C-quoted ("\321\204…" for "ф")
            if let r = RemoteHost.of(cwd) {   // a remote project: the same git, on its host
                args = r.sshArgs(tty: false) + ["cd \(RemoteHost.cdArg(r.path)) && git " + args.map(RemoteHost.quote).joined(separator: " ")]
                executable = RemoteHost.ssh; cwd = NSHomeDirectory()
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"; env["LC_ALL"] = "C"
        env["GIT_OPTIONAL_LOCKS"] = "0"   // a status doesn't rewrite the index (which would wake the file watchers again)
        env.merge(extra) { $1 }
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err
        if stdin != nil { p.standardInput = inp }
        try p.run()
        // A host that drops packets or a credential helper waiting on nobody must not hold this thread for good.
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeLimit, execute: watchdog)
        defer { watchdog.cancel() }
        if let stdin {
            let w = inp.fileHandleForWriting
            _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)   // git (or ssh) gone early fails the write; its exit status says why
            try? w.write(contentsOf: stdin); try? w.close()
        }
        // Drain both pipes concurrently to avoid deadlock on large output. stderr gets a thread of its own: GCD's global
        // queue gets none while every cooperative thread is blocked (callers on the Swift pool, parallel tests) — a hang.
        nonisolated(unsafe) var errData = Data()
        let g = DispatchGroup(); g.enter()
        Thread.detachNewThread { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait(); p.waitUntilExit()
        guard ok.contains(p.terminationStatus) else {
            throw GitError(args: args, status: p.terminationStatus, stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return outData
    }

    /// File names as pathspecs that mean just those files: "[id].tsx" isn't a pattern for "i.tsx" or "d.tsx".
    /// (Not `--literal-pathspecs`: `stash -u` uses pathspec magic of its own and then leaves untracked files behind.)
    static func literal(_ files: [String]) -> [String] { files.map { ":(literal)" + $0 } }

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

    /// Every workspace list asks this for each project: a local checkout's HEAD file answers without a git process.
    /// Detached, a linked worktree (.git is a file), a reftable repository or a remote project: git itself.
    public static func currentBranch(_ path: String) throws -> String {
        if RemoteHost.of(path) == nil, let head = try? String(contentsOfFile: path + "/.git/HEAD", encoding: .utf8), head.hasPrefix("ref: refs/heads/") {
            let name = String(head.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if name != ".invalid" { return name }   // a reftable repository's stub HEAD: the real one is in its tables
        }
        return try run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
