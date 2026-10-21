import AppKit
import Foundation
import Testing
import Core
import WorkbenchKit
@testable import KelpApp

/// What typing, saving and the language server's copy of the text cost the main thread in a file near the editable
/// limit. Opt-in, it takes seconds: KELP_BENCH=1 swift test --filter editorBench
extension SharedAppModel {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KELP_BENCH"] != nil)) func editorBench() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let line = "    let value = compute(index: 42, label: \"größe\") // a line of code\n"
        try rig.write("big.swift", String(repeating: line, count: 4_700_000 / line.utf8.count))
        let p = rig.repo + "/big.swift"
        let tab = FileTab(uri: TabURI.file(p))
        let e = try #require(tab.editor), tv = try #require(e.controller.textView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = tab.view
        window.contentView?.layoutSubtreeIfNeeded()
        func time(_ n: Int, _ body: () -> Void) -> Double {
            let t0 = Date(); for _ in 0..<n { body() }; return Date().timeIntervalSince(t0) * 1000 / Double(n)
        }
        let end = tv.textStorage.length - 100   // at the end: a compare with the saved text runs through all of it
        let onChange = e.onChange
        e.onChange = nil
        let bare = time(30) { tv.replaceCharacters(in: NSRange(location: end, length: 0), with: "x") }
        e.onChange = onChange
        let typed = time(30) { tv.replaceCharacters(in: NSRange(location: end, length: 0), with: "x") }
        #expect(tab.isEdited)
        let t0 = Date()
        #expect(await tab.save())
        let save = Date().timeIntervalSince(t0) * 1000
        #expect(!tab.isEdited)
        let overtype = time(10) { tv.replaceCharacters(in: NSRange(location: end, length: 1), with: "y") }   // the saved length
        let text = e.text
        let lsp = time(1) { LSPManager.shared.change(root: rig.repo, path: p, text: text) }
        print(String(format: "BENCH editor %.1f MB on the main thread: keystroke %.2f ms (the editor alone %.2f), same-length edit %.2f ms, lsp.change %.2f ms; save took %.0f ms",
                     Double(text.utf8.count) / 1e6, typed, bare, overtype, lsp, save))
    }
}
