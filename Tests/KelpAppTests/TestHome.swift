import Foundation

/// KelpApp code reads `Paths` (scratch, extensions, skills) and agents' folders: these tests run with KELP_HOME,
/// CLAUDE_CONFIG_DIR and CODEX_HOME in a throwaway folder, replacing any inherited ones (an agent inside Kelp running
/// `swift test` has the real KELP_HOME), so nothing reads or writes the user's own. KELP_TEST_ISOLATED: done once.
let testHome: String = {
    if getenv("KELP_TEST_ISOLATED") == nil {
        let h = NSTemporaryDirectory() + "kelp-app-tests-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: h, withIntermediateDirectories: true)
        setenv("KELP_HOME", h + "/home", 1)
        setenv("CLAUDE_CONFIG_DIR", h + "/claude", 1)
        setenv("CODEX_HOME", h + "/codex", 1)
        setenv("KELP_KEYCHAIN_SERVICE", "dev.kelp.tests.\(UUID().uuidString)", 1)
        setenv("KELP_TEST_ISOLATED", "1", 1)
    }
    return String(cString: getenv("KELP_HOME"))
}()
