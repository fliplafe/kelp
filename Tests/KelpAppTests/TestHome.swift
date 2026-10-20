import Foundation

import TestSupport

/// KelpApp code reads `Paths` (scratch, extensions, skills) and agents' folders: the process is isolated (TestIsolation).
let testHome: String = { _ = TestIsolation.root; return String(cString: getenv("KELP_HOME")) }()
