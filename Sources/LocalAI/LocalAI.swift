import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Small on-device model (Apple Foundation Models) for quality-of-life text: names, summaries, drafts.
/// Every call returns nil when the model is unavailable, so callers keep a deterministic fallback.
public enum LocalAI {
    public static var isAvailable: Bool {
        guard UserDefaults.standard.object(forKey: "localAIEnabled") as? Bool ?? true else { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { if case .available = SystemLanguageModel.default.availability { return true } }
        #endif
        return false
    }

    public struct Naming: Sendable, Equatable { public var title: String; public var branch: String }
    public struct AgentState: Sendable, Equatable { public var waitingForUser: Bool; public var summary: String }
    public struct PR: Sendable, Equatable { public var title: String; public var body: String }

    /// Tab title + branch name for a task prompt.
    public static func naming(for prompt: String) async -> Naming? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable {
            let s = LanguageModelSession(instructions: "You name software tasks for a developer's tools.")
            if let r = try? await s.respond(to: "Task prompt: \(prompt.prefix(1500))", generating: GNaming.self) {
                let b = Fallback.slug(r.content.branch)
                return Naming(title: r.content.title, branch: b.isEmpty ? Fallback.slug(prompt) : b)
            }
        }
        #endif
        return nil
    }

    /// Read the tail of an agent's terminal: is it asking the user something, and what happened.
    public static func agentState(tail: String) async -> AgentState? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable {
            let s = LanguageModelSession(instructions: "You read the last lines of a coding agent's terminal (Claude Code, Codex, etc.).")
            if let r = try? await s.respond(to: "Terminal tail:\n\(tail.suffix(2500))", generating: GState.self) {
                return AgentState(waitingForUser: r.content.waitingForUser, summary: r.content.summary)
            }
        }
        #endif
        return nil
    }

    public static func commitMessage(diff: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable {
            let s = LanguageModelSession(instructions: "Write git commit messages: imperative subject line under 60 characters, then an optional short body. Output only the message.")
            if let r = try? await s.respond(to: "Staged diff (may be truncated):\n\(diff.prefix(6000))") {
                return r.content.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "```", with: "")
            }
        }
        #endif
        return nil
    }

    public static func pullRequest(branch: String, commits: [String], diffStat: String, issue: String?) async -> PR? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable {
            let s = LanguageModelSession(instructions: "Write pull request titles and short descriptions: what problem, what changed, how to test. Plain markdown.")
            let prompt = "Branch: \(branch)\nCommits:\n\(commits.prefix(30).joined(separator: "\n"))\nFiles:\n\(diffStat.prefix(2500))" + (issue.map { "\nLinked issue: \($0)" } ?? "")
            if let r = try? await s.respond(to: prompt, generating: GPR.self) {
                var body = r.content.body
                if let issue, !body.contains(issue) { body += "\n\nFixes \(issue)" }
                return PR(title: r.content.title, body: body)
            }
        }
        #endif
        return nil
    }
}

/// Deterministic fallbacks used when no model is around.
public enum Fallback {
    static let stop: Set<String> = ["a", "an", "the", "to", "and", "of", "for", "in", "on", "with", "please", "can", "you", "it", "this", "that", "is", "be", "we"]
    /// "Add a dark-mode toggle to Settings!" -> "add-dark-mode-toggle-settings"
    public static func slug(_ s: String, words: Int = 5) -> String {
        let parts = s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { !stop.contains($0) && $0.allSatisfy(\.isASCII) }
        return parts.prefix(words).joined(separator: "-")
    }
    public static func title(_ s: String) -> String {
        let first = s.split(separator: "\n").first.map(String.init) ?? s
        return first.count > 40 ? String(first.prefix(39)) + "…" : first
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable struct GNaming {
    @Guide(description: "Short title for this coding task, 2-5 words, Title Case") var title: String
    @Guide(description: "git branch name for this task: lowercase kebab-case, 2-5 words describing the change, no prefix") var branch: String
}
@available(macOS 26, *)
@Generable struct GState {
    @Guide(description: "true if the agent is asking the user a question, waiting for approval, or showing a choice; false if it finished or is still working") var waitingForUser: Bool
    @Guide(description: "One short sentence, under 15 words: what the agent did, or what it is asking") var summary: String
}
@available(macOS 26, *)
@Generable struct GPR {
    @Guide(description: "Pull request title under 70 characters") var title: String
    @Guide(description: "Markdown body: 'Problem', 'Changes', 'Testing' sections, concise") var body: String
}
#endif
