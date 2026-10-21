import Foundation
import TestSupportC

/// One isolation for the whole test process, set up as it loads (TestSupportC's constructor), before any test of any
/// target runs, whichever runs first or alone:
/// - keys (Jira, Linear, agent secrets) go to a keychain service of their own, never the real one;
/// - KELP_HOME, CLAUDE_CONFIG_DIR and CODEX_HOME are throwaway folders and PATH is given (KELP_LOGIN_PATH): nothing reads
///   the user's ~/.kelp, ~/.claude or ~/.codex, nor runs their shell profile;
/// - git reads no ~/.gitconfig or system config (signing, hooks, templates).
/// Values inherited from outside are replaced, not kept: `swift test` run by an agent inside Kelp inherits the real
/// KELP_HOME (and a profile's config dir).
public enum TestIsolation {
    /// The process's own folder, removed when it exits.
    public static let root: String = {
        let r = String(cString: kelp_test_root())
        precondition(!r.isEmpty && ProcessInfo.processInfo.environment["KELP_TEST_ISOLATED"] == "1", "test isolation didn't run")
        atexit { try? FileManager.default.removeItem(atPath: TestIsolation.root) }
        return r
    }()

    /// The keychain service the tests' keys go to.
    public static var keychainService: String { _ = root; return ProcessInfo.processInfo.environment["KELP_KEYCHAIN_SERVICE"] ?? "" }
}
