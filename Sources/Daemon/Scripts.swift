import Foundation
import CryptoKit
import Core

/// A project's commands from `.krill.yaml` (setup, run, test…) run only after the user trusts that file: a clone
/// mustn't run anything just by being opened. Trust is for the file's exact contents; editing it asks again.
extension Daemon {
    private var trustFile: URL { root.appendingPathComponent("trusted-configs.json") }

    private func configText(_ repoPath: String) -> String { (try? String(contentsOfFile: repoPath + "/.krill.yaml", encoding: .utf8)) ?? "" }
    private static func digest(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Nothing to run counts as trusted.
    func trusted(repoPath: String) -> Bool {
        let text = configText(repoPath), cfg = RepoConfig.parse(text)
        guard cfg.setup != nil || !cfg.scripts.isEmpty else { return true }
        let known = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: trustFile))) ?? [:]
        return known[repoPath] == Self.digest(text)
    }

    func handleScripts(_ method: String, _ p: JSONValue, conn: Int) throws -> JSONValue? {
        switch method {
        case "scripts.list":   // {worktreeId} → {scripts: [{name, command}], setup, trusted, file}
            let w = try cwd(forWorktree: p.req("worktreeId"))
            let repo = try store.repo(w.repoId)?.path ?? w.path, cfg = RepoConfig.load(repoPath: repo)
            return .obj(["scripts": try .from(cfg.scripts), "setup": cfg.setup.map { .string($0) } ?? .null,
                         "trusted": .bool(trusted(repoPath: repo)), "file": .string(repo + "/.krill.yaml")])
        case "scripts.trust":   // {worktreeId}: the project's .krill.yaml as it is now may run
            let w = try cwd(forWorktree: p.req("worktreeId"))
            let repo = try store.repo(w.repoId)?.path ?? w.path
            var known = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: trustFile))) ?? [:]
            known[repo] = Self.digest(configText(repo))
            try JSONEncoder().encode(known).write(to: trustFile, options: .atomic)
            return .null
        case "scripts.run":   // {worktreeId, name} → the session running it (in the workspace's folder)
            let w = try cwd(forWorktree: p.req("worktreeId"))
            let repo = try store.repo(w.repoId)?.path ?? w.path
            guard trusted(repoPath: repo) else { throw RPCError.invalidParams("This project's commands aren't trusted yet.") }
            let name = try p.req("name"), cfg = RepoConfig.load(repoPath: repo)
            guard let s = cfg.scripts.first(where: { $0.name == name }) ?? cfg.setup.flatMap({ name == "setup" ? .init(name: name, command: $0) : nil }) else {
                throw RPCError.invalidParams("No “\(name)” command in .krill.yaml.")
            }
            var o = Launch(); o.title = name
            return try .from(spawn(cwd: w.path, manifest: .custom(s.command), worktreeId: w.id, o))
        default: return nil
        }
    }
}
