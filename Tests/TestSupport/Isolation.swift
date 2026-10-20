import Foundation

/// One isolation for every test target (they all run in one process): the first to ask sets all of it, so nothing
/// depends on which target happens to start first.
/// - keys (Jira, Linear, agent secrets) go to a keychain service of their own, never the real one;
/// - KELP_HOME, CLAUDE_CONFIG_DIR and CODEX_HOME are throwaway folders and PATH is given (KELP_LOGIN_PATH): nothing reads
///   the user's ~/.kelp, ~/.claude or ~/.codex, nor runs their shell profile;
/// - git reads no ~/.gitconfig or system config (signing, hooks, templates).
/// Values inherited from outside are replaced, not kept: `swift test` run by an agent inside Kelp inherits the real
/// KELP_HOME (and a profile's config dir).
public enum TestIsolation {
    /// The process's own folder (short: a Unix socket path inside it has to fit in 104 bytes), removed when it exits.
    public static let root: String = {
        let r = "/tmp/kr-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: r, withIntermediateDirectories: true)
        let vars = ["KELP_HOME": r + "/home", "CLAUDE_CONFIG_DIR": r + "/claude", "CODEX_HOME": r + "/codex",
                    "KELP_LOGIN_PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                    "KELP_KEYCHAIN_SERVICE": "dev.kelp.tests.\(UUID().uuidString)",
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "KELP_TEST_ISOLATED": "1"]
        for (k, v) in vars { setenv(k, v, 1) }
        atexit { try? FileManager.default.removeItem(atPath: TestIsolation.root) }
        return r
    }()

    /// The keychain service the tests' keys go to.
    public static var keychainService: String { _ = root; return ProcessInfo.processInfo.environment["KELP_KEYCHAIN_SERVICE"] ?? "" }
}
