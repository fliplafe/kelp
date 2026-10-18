import Foundation
import Core

public enum ReviewMessage {
    /// All open comments as one message for the agent: file, lines, code quote, remark.
    public static func compose(branch: String, comments: [DiffComment]) -> String {
        var s = "Review comments on branch \(branch). Please address each one:\n"
        for (i, c) in comments.enumerated() {
            let range = c.startLine == c.endLine ? "\(c.startLine)" : "\(c.startLine)-\(c.endLine)"
            s += "\n\(i + 1). \(c.file):\(range)\n"
            for l in c.quote.split(separator: "\n", omittingEmptySubsequences: false) { s += "   > \(l)\n" }
            s += "   \(c.text)\n"
        }
        return s
    }
}

/// `.krill.yaml`: flat `key: value` lines. Deliberately not full YAML.
///   setup / run / test: shell commands      shared: node_modules, .venv   (symlinked into each worktree)
///   tabs: claude, shell   (sessions opened in a new worktree)      issueCommand: prompt template for issue worktrees
///   recipe.<action>: prompt template with {stagedPatch} {branch} {diffStat} {error} {linkedIssue}
public struct RepoConfig: Sendable, Equatable {
    public var setup: String?, run: String?, test: String?, issueCommand: String?
    public var shared: [String] = [], tabs: [String] = []
    public var recipes: [String: String] = [:]

    public static func parse(_ text: String) -> RepoConfig {
        var c = RepoConfig()
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let i = t.firstIndex(of: ":") else { continue }
            var v = t[t.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) { v = String(v.dropFirst().dropLast()) }
            let list = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let key = String(t[..<i])
            switch key {
            case "setup": c.setup = v
            case "run": c.run = v
            case "test": c.test = v
            case "issueCommand": c.issueCommand = v
            case "shared": c.shared = list
            case "tabs": c.tabs = list
            default: if key.hasPrefix("recipe.") { c.recipes[String(key.dropFirst(7))] = v.replacingOccurrences(of: "\\n", with: "\n") }
            }
        }
        return c
    }
    public static func load(repoPath: String) -> RepoConfig {
        parse((try? String(contentsOfFile: repoPath + "/.krill.yaml", encoding: .utf8)) ?? "")
    }
}

/// Prompt templates for agent actions; a repo's `recipe.<name>` overrides the default.
public enum Recipes {
    public static let defaults: [String: String] = [
        "commit": "Write a concise commit message for these staged changes and run `git commit` with it.\n\n{stagedPatch}",
        "fixCommit": "`git commit` failed (hooks or checks). Fix the problems, re-stage, and commit again.\n\nError:\n{error}",
        "fixPush": "`git push` failed. Fix the cause (e.g. rebase on the remote branch, resolve conflicts) and push again.\n\nError:\n{error}",
        "pr": "Open a pull request for branch {branch} with `gh pr create`. Write a short title and a description: problem, changes, how to test. {linkedIssue}",
        "resolveConflicts": "Merge {base} into this branch, resolve all conflicts ({files}), run the tests, and commit.",
        "fixCI": "CI check \"{check}\" failed on this branch. Here is the log tail; fix the cause and push.\n\n{error}",
        "review": "Address these review comments from the pull request:\n\n{comments}",
        "issue": "{title}\n\n{body}\n\n(Issue: {url})",
    ]
    public static func render(_ name: String, config: RepoConfig, vars: [String: String]) -> String {
        var t = config.recipes[name] ?? defaults[name] ?? ""
        for (k, v) in vars { t = t.replacingOccurrences(of: "{\(k)}", with: v) }
        return t
    }
}
