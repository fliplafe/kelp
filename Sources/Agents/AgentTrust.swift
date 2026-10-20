import Foundation

/// Folders an agent already trusts, read from its own config (never written). Kelp answers an agent's "trust this
/// folder?" itself only inside them; anywhere else the question is the user's, as the agent intends (a repository's own
/// agent settings can run hooks and servers the moment it's trusted).
public enum AgentTrust {
    /// Whether `agent` trusts any of `folders` (or a folder above one). `env` is the session's: an account profile can point
    /// the agent at a config of its own (CLAUDE_CONFIG_DIR, CODEX_HOME).
    public static func trusts(agent: String, folders: [String], env: [String: String] = [:], home: String = NSHomeDirectory()) -> Bool {
        let trusted = trustedFolders(agent: agent, env: env, home: home).map(normal)
        return folders.map(normal).contains { f in trusted.contains { t in f == t || f.hasPrefix(t == "/" ? "/" : t + "/") } }
    }

    public static func trustedFolders(agent: String, env: [String: String], home: String) -> [String] {
        switch agent {
        case "claude": claude(env["CLAUDE_CONFIG_DIR"].map { $0 + "/.claude.json" } ?? home + "/.claude.json")
        case "codex": codex((env["CODEX_HOME"] ?? home + "/.codex") + "/config.toml")
        case "gemini": gemini(home + "/.gemini/trustedFolders.json")
        default: []   // no way to read its trust: Kelp doesn't answer for it
        }
    }

    /// `projects[path].hasTrustDialogAccepted`.
    static func claude(_ file: String) -> [String] {
        guard let d = FileManager.default.contents(atPath: file), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let projects = o["projects"] as? [String: Any] else { return [] }
        return projects.compactMap { path, v in (v as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true ? path : nil }
    }

    /// `[projects."<path>"]` sections with `trust_level = "trusted"`.
    static func codex(_ file: String) -> [String] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        var out: [String] = [], section: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line.hasPrefix("[projects.\"") && line.hasSuffix("\"]") ? String(line.dropFirst(11).dropLast(2)) : nil
            } else if let s = section, line.replacingOccurrences(of: " ", with: "") == "trust_level=\"trusted\"" {
                out.append(s)
            }
        }
        return out
    }

    /// `{"<path>": "TRUST_FOLDER" | "TRUST_PARENT" | "DO_NOT_TRUST"}`; a trusted parent covers the folders in it.
    static func gemini(_ file: String) -> [String] {
        guard let d = FileManager.default.contents(atPath: file), let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [] }
        return o.compactMap { path, level in
            level == "TRUST_FOLDER" ? path : level == "TRUST_PARENT" ? (path as NSString).deletingLastPathComponent : nil
        }
    }

    /// Symlinks resolved where the folder exists (/tmp is /private/tmp), no trailing slash.
    static func normal(_ p: String) -> String {
        let real = realpath(p, nil).map { r in defer { free(r) }; return String(cString: r) } ?? p
        return real.count > 1 && real.hasSuffix("/") ? String(real.dropLast()) : real
    }
}
