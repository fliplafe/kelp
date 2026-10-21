import AppKit
import Foundation
import Testing
import Core
@testable import KelpApp

/// Language servers run a project's own code (build scripts, Package.swift, its node_modules' TypeScript): none starts
/// in a project until the user trusts it, and the tabs that wanted one start it then.
extension SharedAppModel {
    @Test func languageServersWaitForTheUsersTrustInTheProject() async throws {
        _ = testHome
        _ = NSApplication.shared   // the question is a banner in the window
        let saved = UIState[LSPManager.trustKey]
        defer { UIState[LSPManager.trustKey] = saved }
        let root = "/tmp/cloned-\(UUID().uuidString.prefix(6))"
        let lsp = LSPManager.shared
        var started = 0
        #expect(!lsp.whenTrusted(root) { started += 1 })        // asks; nothing starts
        #expect(!lsp.whenTrusted(root) { started += 1 })        // a second tab of it waits too (asked once)
        #expect(await lsp.client(root: root, path: root + "/main.rs") == nil)
        #expect(started == 0 && !lsp.trusted(root))
        lsp.trust(root)                                          // the banner's "Trust and Start"
        #expect(started == 2 && lsp.trusted(root))
        #expect(lsp.whenTrusted(root) { started += 1 } && started == 2)   // trusted from now on: no waiting
        #expect(!lsp.trusted(Paths.scratch.path))   // the scratch desk is asked about like any project: a clone may land there
    }
}
