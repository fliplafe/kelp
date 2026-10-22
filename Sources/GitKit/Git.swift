import Foundation
import Core

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

/// Running the system git (the daemon's). Behaviour matches what you'd see in a terminal.
extension Git {
    @discardableResult
    public static func run(_ args: [String], cwd: String, stdin: String? = nil, executable: String = "/usr/bin/git", ok: Set<Int32> = [0],
                           env extra: [String: String] = [:], remotes: Remotes = .none) throws -> String {
        String(decoding: try runData(args, cwd: cwd, stdin: stdin.map { Data($0.utf8) }, executable: executable, ok: ok, env: extra, remotes: remotes), as: UTF8.self)
    }

    /// `run`, its output as the bytes git wrote (a diff of a file that isn't UTF-8 goes back to `git apply` unchanged).
    /// More than `Subprocess.outputLimit` of it is an error: nothing here works on a part as if it were the whole.
    @discardableResult
    public static func runData(_ args: [String], cwd: String, stdin: Data? = nil, executable: String = "/usr/bin/git", ok: Set<Int32> = [0],
                               env extra: [String: String] = [:], timeLimit: TimeInterval = 300, remotes: Remotes = .none) throws -> Data {
        let r = try runPart(args, cwd: cwd, stdin: stdin, executable: executable, ok: ok, env: extra, timeLimit: timeLimit, limit: Subprocess.outputLimit, remotes: remotes)
        guard !r.truncated else { throw tooMuch(args) }
        return r.data
    }

    static func tooMuch(_ args: [String]) -> GitError {
        GitError(args: args, status: 0, stderr: "It printed more than \(Subprocess.outputLimit >> 20) MB, more than Kelp reads.")
    }

    /// `runData` keeping the first `limit` bytes of the output: `truncated` says there was more (read and dropped), for a
    /// caller that shows a part (a long status, a huge diff) and says so.
    static func runPart(_ args: [String], cwd: String, stdin: Data? = nil, executable: String = "/usr/bin/git", ok: Set<Int32> = [0],
                        env extra: [String: String] = [:], timeLimit: TimeInterval = 300, limit: Int, remotes: Remotes = .none) throws -> (data: Data, truncated: Bool) {
        // timeLimit: longest a git / gh / ssh run may take before it's stopped (it then fails like any other error). Five
        // minutes: far past any real fetch or push, short of a thread lost for good.
        var args = args, executable = executable, cwd = cwd
        if executable == "/usr/bin/git" {
            // Paths as they are, not C-quoted ("\321\204…" for "ф"). No fsmonitor: a folder's own .git/config (one that
            // came in a download, not a clone) would otherwise have every status Kelp runs start its program.
            args = ["-c", "core.quotePath=false", "-c", "core.fsmonitor=false"] + args
            if let r = remotes.of(cwd) {   // a remote project: the same git, on its host
                args = r.sshArgs(tty: false) + ["cd \(RemoteHost.cdArg(r.path)) && git " + args.map(RemoteHost.quote).joined(separator: " ")]
                executable = r.ssh; cwd = NSHomeDirectory()
            }
        }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"; env["LC_ALL"] = "C"
        env["GIT_OPTIONAL_LOCKS"] = "0"   // a status doesn't rewrite the index (which would wake the file watchers again)
        env.merge(extra) { $1 }
        // A host that drops packets or a credential helper waiting on nobody is stopped at the time limit, with its children.
        let r = try Subprocess.run([executable] + args, cwd: cwd, env: env, stdin: stdin, timeLimit: timeLimit, limit: limit)
        guard ok.contains(r.status), !r.timedOut else {
            throw GitError(args: args, status: r.status, stderr: String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (r.stdout, r.truncated)
    }

    /// `d` up to its last `separator`, inclusive: the whole entries of output cut off mid-entry.
    static func wholeEntries(_ d: Data, _ separator: UInt8) -> Data { d.lastIndex(of: separator).map { d[...$0] } ?? Data() }

    /// File names as pathspecs that mean just those files: "[id].tsx" isn't a pattern for "i.tsx" or "d.tsx".
    /// (Not `--literal-pathspecs`: `stash -u` uses pathspec magic of its own and then leaves untracked files behind.)
    static func literal(_ files: [String]) -> [String] { files.map { ":(literal)" + $0 } }

    public static func root(of path: String, remotes: Remotes = .none) throws -> String {
        try run(["rev-parse", "--show-toplevel"], cwd: path, remotes: remotes).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A branch name Kelp may pass to git as a revision: never one that reads as an option. Git won't create such a
    /// name, but a cloned repository's HEAD can point at one (refs/heads/--output=/some/file), and `git diff <it>` would
    /// take it as --output and overwrite that file. Names read from git go through this; names from clients through
    /// the daemon's `ref`.
    public static func isRevision(_ name: String) -> Bool { !name.isEmpty && !name.hasPrefix("-") }

    /// `name` as a revision or branch argument, wherever it came from (a client, the database, git's own output): every
    /// GitKit call that puts one where git reads options goes through this, so none can become an option.
    static func rev(_ name: String) throws -> String {
        guard isRevision(name) else { throw GitError(args: [name], status: 1, stderr: "“\(name)” isn't a branch or commit name.") }
        return name
    }

    /// Default branch: origin/HEAD if set, else current branch of the main checkout.
    public static func defaultBranch(repo: String, remotes: Remotes = .none) -> String {
        if let s = try? run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: repo, remotes: remotes) {
            let b = String(s.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 != "/" }).dropFirst())
            if isRevision(b) { return b }
        }
        for b in ["main", "master"] where (try? run(["rev-parse", "--verify", b], cwd: repo, remotes: remotes)) != nil { return b }
        return (try? currentBranch(repo, remotes: remotes)) ?? "main"
    }

    /// Every workspace list asks this for each project: a local checkout's HEAD file answers without a git process.
    /// Detached, a linked worktree (.git is a file), a reftable repository or a remote project: git itself.
    public static func currentBranch(_ path: String, remotes: Remotes = .none) throws -> String {
        var name = ""
        if remotes.of(path) == nil, let head = try? String(contentsOfFile: path + "/.git/HEAD", encoding: .utf8), head.hasPrefix("ref: refs/heads/") {
            name = String(head.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if name == ".invalid" { name = "" }   // a reftable repository's stub HEAD: the real one is in its tables
        }
        if name.isEmpty { name = try run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path, remotes: remotes).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard isRevision(name) else { throw GitError(args: ["rev-parse", "HEAD"], status: 1, stderr: "the branch's name reads as an option: \(name)") }
        return name
    }
}

extension RemoteHost {
    /// `script` in sh on the host (whatever its login shell is), its output as the bytes it wrote.
    public func run(_ script: String) throws -> Data {
        try Git.runData(sshArgs(tty: false) + ["sh -c " + Self.quote(script)], cwd: NSHomeDirectory(), executable: ssh)
    }
}
