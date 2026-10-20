import Foundation
import CryptoKit
import Core

/// A project's commands from `.kelp.yaml` (setup, run, test…) run only after the user trusts that file: a clone
/// mustn't run anything just by being opened. Trust is for the file's exact contents; editing it asks again.
extension Daemon {
    private var trustFile: URL { root.appendingPathComponent("trusted-configs.json") }

    private func configText(_ repoPath: String) -> String { (try? String(contentsOfFile: repoPath + "/.kelp.yaml", encoding: .utf8)) ?? "" }
    private static func digest(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// The file read once, its parsed config and whether the user trusts exactly that text: checking one read and using
    /// another would let a write in between (an agent, a pull) slip in unseen.
    func configAndTrust(_ repoPath: String) -> (text: String, config: RepoConfig, trusted: Bool) {
        let text = configText(repoPath), cfg = RepoConfig.parse(text)
        guard !Self.asksNothing(cfg) else { return (text, cfg, true) }
        return (text, cfg, trustLock.withLock { knownDigests() }[repoPath] == Self.digest(text))
    }

    /// Nothing to run counts as trusted.
    func trusted(repoPath: String) -> Bool { configAndTrust(repoPath).trusted }

    /// trusted-configs.json is read and written under one lock: two projects trusted at once both stay trusted.
    private func knownDigests() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: trustFile))) ?? [:]
    }

    /// Nothing in it runs, links, or speaks to an agent for the user: a file like that needs no trust.
    static func asksNothing(_ c: RepoConfig) -> Bool {
        c.setup == nil && c.scripts.isEmpty && c.tabs.isEmpty && c.shared.isEmpty && c.recipes.isEmpty && c.issueCommand == nil
    }

    /// The project's .kelp.yaml if the user trusts it as it is now, else nothing of it: a cloned repository's prompts
    /// (recipe.*, issueCommand) reach an agent as the user's own words, so they wait for trust like its commands.
    func trustedConfig(_ repoPath: String) -> RepoConfig {
        let c = configAndTrust(repoPath)
        return c.trusted ? c.config : RepoConfig()
    }

    /// KelpApp beside this daemon (one bundle, or one build folder); KELP_APP_EXECUTABLE stands in for it in tests.
    static var appExecutable: String {
        if let e = ProcessInfo.processInfo.environment["KELP_APP_EXECUTABLE"] { return URL(fileURLWithPath: e).resolvingSymlinksInPath().path }
        let me = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return me.deletingLastPathComponent().appendingPathComponent("KelpApp").resolvingSymlinksInPath().path
    }

    func handleScripts(_ method: String, _ p: JSONValue, conn: Int) throws -> JSONValue? {
        switch method {
        case "scripts.list":   // {worktreeId} → {scripts: [{name, command}], setup, trusted, file}
            let w = try cwd(forWorktree: p.req("worktreeId"))
            let repo = try store.repo(w.repoId)?.path ?? w.path, read = configAndTrust(repo), cfg = read.config
            // Everything trusting it would allow, and the digest of exactly this text (one read): trust is given to what was shown.
            return .obj(["scripts": try .from(cfg.scripts), "setup": cfg.setup.map { .string($0) } ?? .null,
                         "tabs": try .from(cfg.tabs), "shared": try .from(cfg.shared), "recipes": try .from(cfg.recipes),
                         "issueCommand": cfg.issueCommand.map { .string($0) } ?? .null,
                         "digest": .string(Self.digest(read.text)),
                         "trusted": .bool(read.trusted), "file": .string(repo + "/.kelp.yaml")])
        case "scripts.trust":   // {worktreeId}: the project's .kelp.yaml as it is now may run
            let w = try cwd(forWorktree: p.req("worktreeId"))
            let repo = try store.repo(w.repoId)?.path ?? w.path
            let now = Self.digest(configText(repo))
            // {digest} from scripts.list: the file changed since it was shown (an agent, a pull), so that isn't what was trusted.
            // Only from Kelp's window: the program on the other end of the socket must be the KelpApp next to this daemon.
            // Agents and scripts reach this socket too (KELP_SOCKET) and could read the digest; they can't become that
            // program. (The limit: a process of this user can still drive the app itself, e.g. with synthetic key events.)
            guard let peer = lock.withLock({ conns[conn]?.peer }), peer == Self.appExecutable else {
                throw RPCError.invalidParams("Only Kelp's window can trust a project's commands: open the project there and run one.")
            }
            guard let shown = p["digest"]?.string else { throw RPCError.invalidParams("scripts.trust needs the digest of the .kelp.yaml that was shown.") }
            if shown != now {
                throw RPCError.invalidParams(".kelp.yaml changed since it was shown. Look at it again before trusting it.")
            }
            try trustLock.withLock {
                var known = knownDigests()
                known[repo] = now
                try JSONEncoder().encode(known).write(to: trustFile, options: .atomic)
            }
            return .null
        case "scripts.run":   // {worktreeId, name} → the session running it (in the workspace's folder)
            let w = try cwd(forWorktree: p.req("worktreeId"))
            let repo = try store.repo(w.repoId)?.path ?? w.path
            let read = configAndTrust(repo)   // the command run is from the text that was checked
            guard read.trusted else { throw RPCError.invalidParams("This project's commands aren't trusted yet.") }
            let name = try p.req("name"), cfg = read.config
            guard let s = cfg.scripts.first(where: { $0.name == name }) ?? cfg.setup.flatMap({ name == "setup" ? .init(name: name, command: $0) : nil }) else {
                throw RPCError.invalidParams("No “\(name)” command in .kelp.yaml.")
            }
            var o = Launch(); o.title = name
            return try .from(spawn(cwd: w.path, manifest: .custom(s.command), worktreeId: w.id, o))
        default: return nil
        }
    }
}
