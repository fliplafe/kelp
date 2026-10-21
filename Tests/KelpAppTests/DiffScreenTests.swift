import AppKit
import Foundation
import Testing
import Core
import GitKit
import Daemon
@testable import KelpApp

@MainActor private func buttons(in v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
@MainActor private func tables(in v: NSView) -> [NSTableView] { ((v as? NSTableView).map { [$0] } ?? []) + v.subviews.flatMap(tables) }
/// Every cell of every table, made as a window on screen would (offscreen, tables make none until asked).
@MainActor private func cells(in v: NSView) -> [NSView] {
    tables(in: v).flatMap { t in (0..<t.numberOfRows).flatMap { r in (0..<t.numberOfColumns).compactMap { t.view(atColumn: $0, row: r, makeIfNecessary: true) } } }
}

/// The diff of one file as the user sees it, against a real daemon and repository: its Stage buttons stage that hunk
/// and only that one.
extension SharedAppModel {
    @Test func aHunksStageButtonStagesThatHunk() async throws {
        let lines = (1...40).map { "line \($0)" }
        let rig = try await AppRig(files: ["f.txt": lines.joined(separator: "\n") + "\n"]); defer { rig.done() }
        var changed = lines; changed[2] = "top change"; changed[35] = "bottom change"   // two hunks, far apart
        try rig.write("f.txt", changed.joined(separator: "\n") + "\n")
        let wt = rig.workspace, repo = rig.repo
        let vc = DiffViewController()
        rig.show(vc, 900, 700)
        vc.showFile("f.txt", source: "unstaged", commit: nil)
        vc.show(worktree: wt.id)
        await vc.load()
        vc.view.layoutSubtreeIfNeeded()
        func stageButtons() -> [NSButton] { cells(in: vc.view).flatMap(buttons).filter { $0.action.map(NSStringFromSelector) == "hunkAction:" } }
        for _ in 0..<50 where stageButtons().count < 2 { try await Task.sleep(for: .milliseconds(50)); vc.view.layoutSubtreeIfNeeded() }
        let stage = stageButtons()
        try #require(stage.count == 2, "\(stage.count) stage buttons")
        stage[1].performClick(nil)   // the second hunk: "bottom change"
        var cached = ""
        for _ in 0..<100 where cached.isEmpty { try await Task.sleep(for: .milliseconds(50)); cached = try Git.run(["diff", "--cached"], cwd: repo) }
        #expect(cached.contains("+bottom change") && !cached.contains("+top change"))
    }
}

/// A folder Files can't list (moved away under Kelp, git refusing it) says why where the tree would be: it used to be
/// an empty tree, the same as an empty folder.
extension SharedAppModel {
    @Test func theFilesPanelSaysWhyItShowsNoFiles() async throws {
        let rig = try await AppRig(files: [:]); defer { rig.done() }
        try FileManager.default.removeItem(atPath: rig.repo)   // moved away: nothing can list it now
        let panel = FilesPanel()
        rig.show(panel, 300, 500)
        await withCheckedContinuation { k in panel.reloadTree { k.resume() } }
        @MainActor func labels(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(labels) }
        let said = labels(panel.view).filter { !$0.isHidden && $0.stringValue.contains("Couldn't list the files") }
        #expect(said.count == 1, "\(labels(panel.view).map(\.stringValue))")
    }
}
