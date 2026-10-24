import Testing
@testable import KelpApp
@testable import KelpKit
@testable import BuiltinAgents
@testable import BuiltinFiles
@testable import BuiltinGit
@testable import BuiltinBrowser
@testable import BuiltinIssues
@testable import BuiltinActivity

/// What an extension's badge command prints, as the panel's icon shows it.
@Test func aBadgeCommandsOutputReadsAsANumberOrADot() {
    #expect(PanelBadge("3\n") == PanelBadge(count: 3))
    #expect(PanelBadge("!2") == PanelBadge(count: 2, alert: true))
    #expect(PanelBadge("new build") == PanelBadge(key: "new build"))
    #expect(PanelBadge("! failed") == PanelBadge(alert: true, key: "failed"))
    #expect(PanelBadge("!") == PanelBadge(alert: true))
    for none in ["", " \n", "0", "!0"] { #expect(PanelBadge(none) == nil) }
}
