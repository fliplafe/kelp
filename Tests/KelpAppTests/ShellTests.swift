import Foundation
import Testing
@testable import KelpApp

@Test func agesAreAsShortAsARowAllows() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func ago(_ s: Double) -> String { shortAgo(now.addingTimeInterval(-s), now: now) }
    #expect(ago(5) == "now" && ago(59) == "now")
    #expect(ago(60) == "1m" && ago(3599) == "59m")
    #expect(ago(3600) == "1h" && ago(86399) == "23h")
    #expect(ago(86400 * 3) == "3d")
    #expect(shortAgo(now.addingTimeInterval(60), now: now) == "now")   // a clock a little ahead never shows a negative age
    #expect(shortAgo(nil) == "")
}

@Test func everyBuiltinThemeIsCompleteAndUnique() {
    let themes = Theme.popular
    #expect(Set(themes.map(\.id)).count == themes.count)
    for t in themes {
        guard let term = t.terminal, let palette = term.palette else { Issue.record("\(t.id): no terminal colors"); continue }
        #expect(palette.count == 16, "\(t.id): the terminal needs all 16 ANSI colors")
        #expect(["dark", "light"].contains(t.appearance), "\(t.id)")
        let colors = [term.background, term.foreground, term.cursor, term.selection].compactMap { $0 } + palette
        #expect(colors.allSatisfy { $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }, "\(t.id): a color isn't #rrggbb")
    }
}
