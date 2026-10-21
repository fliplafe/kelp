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
        _ = testHome
        let root = URL(fileURLWithPath: "/tmp/kd-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try Daemon(root: root); try d.start(); defer { d.stop() }
        let c = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for a in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] { try Git.run(a, cwd: repo) }
        let lines = (1...40).map { "line \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], cwd: repo); try Git.run(["commit", "-qm", "init"], cwd: repo)
        var changed = lines; changed[2] = "top change"; changed[35] = "bottom change"   // two hunks, far apart
        try (changed.joined(separator: "\n") + "\n").write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        let r = try await c.call("repo.add", .obj(["path": .string(repo)]), as: Repo.self)
        let wt = try #require(try await c.call("worktree.list", .obj(["repoId": .string(r.id)]), as: [Worktree].self).first)

        let m = AppModel.shared
        let saved = (m.client, m.repos, m.worktrees)
        defer { (m.client, m.repos, m.worktrees) = saved }
        m.client = c; m.repos = [r]; m.worktrees = [wt]
        let vc = DiffViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentViewController = vc
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
        _ = testHome
        let root = URL(fileURLWithPath: "/tmp/kf-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try Daemon(root: root); try d.start(); defer { d.stop() }
        let c = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Git.run(["init", "-q", "-b", "main"], cwd: repo)
        let r = try await c.call(RepoAdd(path: repo))
        let wt = try #require(try await c.call(WorktreeList(repoId: r.id)).first)
        try FileManager.default.removeItem(atPath: repo)   // moved away: nothing can list it now

        let m = AppModel.shared, wb = Workbench.shared
        let saved = (m.client, m.repos, m.worktrees, wb.workspaceId)
        defer { (m.client, m.repos, m.worktrees, wb.workspaceId) = saved }
        m.client = c; m.repos = [r]; m.worktrees = [wt]; wb.workspaceId = wt.id
        let panel = FilesPanel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentViewController = panel
        await withCheckedContinuation { k in panel.reloadTree { k.resume() } }
        @MainActor func labels(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(labels) }
        let said = labels(panel.view).filter { !$0.isHidden && $0.stringValue.contains("Couldn't list the files") }
        #expect(said.count == 1, "\(labels(panel.view).map(\.stringValue))")
    }
}
