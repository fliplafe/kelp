import Foundation
import Testing
import Core
import WorkbenchKit
@testable import KelpApp

private func session(_ status: AgentStatus, unread: Bool = false, agent: String? = "claude", summary: String = "") -> Session {
    Session(cwd: "/", command: "x", agent: agent, status: status, unread: unread, summary: summary)
}

@MainActor @Test func quickOpenRanksPrefixThenWordThenContainsThenSeveralWords() {
    #expect(QuickOpen.wordScore("Open Settings", "open") == 100)
    #expect(QuickOpen.wordScore("Open Settings", "sett") == 80)       // starts a word
    #expect(QuickOpen.wordScore("Open Settings", "ttings") == 60)     // somewhere inside
    #expect(QuickOpen.wordScore("Open Recent Project", "pro rec") == 40)   // every word starts a word, in any order
    #expect(QuickOpen.wordScore("Open Settings", "xyz") == nil)
    #expect(QuickOpen.wordScore("Anything", "  ") == 0)               // an empty query matches everything equally
    #expect(QuickOpen.wordScore("OPEN", "open") == 100)               // case doesn't matter
}

@MainActor @Test func notificationsReadTheFirstSentenceAsAHeadline() {
    #expect(Notifier.firstSentence("I added `mul(a, b)` to `calc.py`. It returns the product.") == "Added mul(a, b) to calc.py")
    #expect(Notifier.firstSentence("I've fixed the login bug!\nMore detail below.") == "Fixed the login bug!")
    #expect(Notifier.firstSentence("Done") == "Done")
    let long = String(repeating: "word ", count: 40)
    let cut = Notifier.firstSentence(long)
    #expect(cut.count == 90 && cut.hasSuffix("…"))   // long text is cut to fit a banner
}

@MainActor @Test func onlyAWaitingAgentAsksForPermission() {
    #expect(Notifier.asksPermission(session(.waiting, summary: "Claude needs your permission to use Bash")))
    #expect(Notifier.asksPermission(session(.waiting, summary: "Allow rm -rf build?")))
    #expect(!Notifier.asksPermission(session(.working, summary: "needs your permission")))   // not waiting any more
    #expect(!Notifier.asksPermission(session(.waiting, summary: "Which file should I edit?")))
}

@MainActor @Test func theSidebarFlagsWhatWantsYou() {
    #expect(SidebarCell.wantsYou(session(.waiting)))
    #expect(SidebarCell.wantsYou(session(.error)))
    #expect(SidebarCell.wantsYou(session(.done, unread: true)))
    #expect(!SidebarCell.wantsYou(session(.done, unread: false)))   // seen
    #expect(!SidebarCell.wantsYou(session(.waiting, agent: "shell")))   // a plain terminal never asks
    #expect(SidebarCell.wantsYou(session(.hibernated, unread: true)))   // paused, but it finished and you haven't looked
    #expect(!SidebarCell.wantsYou(session(.hibernated)))
    #expect(SidebarCell.isNews(session(.done, unread: true)) && !SidebarCell.isNews(session(.idle, unread: true)) && !SidebarCell.isNews(session(.done)))
}

@MainActor @Test func activityNumbersAndPercentagesAreReadable() {
    #expect(ActivityController.number(.int(5)) == 5 && ActivityController.number(.double(2.5)) == 2.5 && ActivityController.number(nil) == 0)
    #expect(ActivityController.number(.string("x")) == 0)
    #expect(ActivityController.percent(0) == "0.0%" && ActivityController.percent(9.94) == "9.9%")
    #expect(ActivityController.percent(10) == "10%" && ActivityController.percent(99.6) == "100%")   // from 10 up no decimals
}

@MainActor @Test func shortcutsShowTheWayMenusDo() {
    func d(_ key: String, _ mods: KeySpec.Modifiers) -> String { KeyBindings.display(KeySpec(key: key, mods: mods)) }
    #expect(d("k", [.shift, .command]) == "⇧⌘K")
    #expect(d("k", [.control, .option, .shift, .command]) == "⌃⌥⇧⌘K")   // the order macOS uses
    #expect(d("\r", [.command]) == "⌘↩" && d("\u{F700}", [.option]) == "⌥↑" && d("\u{7f}", [.command]) == "⌘⌫")
}

@MainActor @Test func aDotInsideAFileNameDoesNotEndTheHeadline() {
    #expect(Notifier.firstSentence("Updated README.md and docs/arch.md. Tests pass.") == "Updated README.md and docs/arch.md")
    #expect(Notifier.firstSentence("Is v1.2 ready? Yes.") == "Is v1.2 ready?")
    #expect(Notifier.firstSentence("Fixed it.") == "Fixed it")
}
