import Foundation

/// KelpApp code reads `Paths` (scratch, extensions, skills): these tests run with KELP_HOME in a throwaway folder, so
/// nothing reads or writes ~/.kelp. The first test target to set it wins; the others keep it.
let testHome: String = {
    if let have = getenv("KELP_HOME") { return String(cString: have) }
    let h = NSTemporaryDirectory() + "kelp-app-tests-\(UUID().uuidString.prefix(6))"
    try? FileManager.default.createDirectory(atPath: h, withIntermediateDirectories: true)
    setenv("KELP_HOME", h, 1)
    return h
}()
