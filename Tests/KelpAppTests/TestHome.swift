import Foundation
import Testing
import TestSupport

/// KelpApp code reads `Paths` (scratch, extensions, skills) and agents' folders: the process is isolated (TestIsolation).
let testHome: String = { _ = TestIsolation.root; return String(cString: getenv("KELP_HOME")) }()

/// Tests that point `AppModel.shared` at a daemon of their own: one at a time, or one would swap the other's client.
@Suite(.serialized) @MainActor struct SharedAppModel {}
