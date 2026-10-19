import Testing
@testable import LocalAI

@Test func fallbackSlug() {
    #expect(Fallback.slug("Add a dark-mode toggle to the Settings screen!") == "add-dark-mode-toggle-settings")
    #expect(Fallback.title("short") == "short")
}

@Test func onDeviceNamingWhenAvailable() async {
    guard LocalAI.isAvailable else { return }
    let n = await LocalAI.naming(for: "Fix the crash when the user logs out twice")
    #expect(n != nil)
    #expect(n!.branch.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
}
