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
        await lsp.trust(root)                                    // the banner's "Trust and Start"
        #expect(started == 2 && lsp.trusted(root))
        #expect(lsp.whenTrusted(root) { started += 1 } && started == 2)   // trusted from now on: no waiting
        #expect(!lsp.trusted(Paths.scratch.path))   // the scratch desk is asked about like any project: a clone may land there
    }

    /// Only Kelp's own window may record trust (the daemon checks who's asking): refused, the project stays untrusted and
    /// nothing starts. It used to be written without an answer and taken as given.
    @Test func trustTheDaemonRefusesIsntTakenAsGiven() async throws {
        _ = NSApplication.shared
        let rig = try await AppRig(); defer { rig.done() }
        let me = ProcessInfo.processInfo.environment["KELP_APP_EXECUTABLE"]   // this test runner stands in for the app…
        setenv("KELP_APP_EXECUTABLE", "/nowhere/KelpApp", 1)                   // …not now: another copy of Kelp is asking
        defer { if let me { setenv("KELP_APP_EXECUTABLE", me, 1) } }
        let root = "/tmp/refused-\(UUID().uuidString.prefix(6))", lsp = LSPManager.shared
        var started = 0
        _ = lsp.whenTrusted(root) { started += 1 }
        await lsp.trust(root)
        #expect(!lsp.trusted(root) && started == 0)
    }
}
