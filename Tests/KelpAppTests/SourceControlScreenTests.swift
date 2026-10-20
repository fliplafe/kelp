import AppKit
import Foundation
import Testing
import Core
import GitKit
import Daemon
@testable import KelpApp

/// Source Control as the user sees it: the real controller, a real daemon and a real git repository, in a window that's
/// never shown. Rows are read back out of its outline.
@MainActor private func texts(_ v: NSView) -> [String] {
    var out: [String] = []
    if let t = v as? NSTextField, !t.stringValue.isEmpty, !t.isHidden { out.append(t.stringValue) }
    for s in v.subviews where !s.isHidden { out += texts(s) }
    return out
}
@MainActor private func outlines(in v: NSView) -> [NSOutlineView] {
    (v as? NSOutlineView).map { [$0] } ?? v.subviews.flatMap(outlines)
}
private func git(_ args: [String], _ cwd: String) throws { _ = try Git.run(args, cwd: cwd) }

extension SharedAppModel {
@Test func sourceControlListsStagedAndChangedFilesFromTheDaemon() async throws {
    _ = testHome
    let root = URL(fileURLWithPath: "/tmp/ks-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let d = try Daemon(root: root); try d.start(); defer { d.stop() }
    let c = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
    let repo = root.appendingPathComponent("repo").path
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], repo); try git(["config", "user.email", "t@t"], repo); try git(["config", "user.name", "t"], repo)
    try "a\n".write(toFile: repo + "/kept.txt", atomically: true, encoding: .utf8); try git(["add", "."], repo); try git(["commit", "-qm", "init"], repo)
    let r = try await c.call("repo.add", .obj(["path": .string(repo)]), as: Repo.self)
    let wt = try #require(try await c.call("worktree.list", .obj(["repoId": .string(r.id)]), as: [Worktree].self).first)
    try "b\n".write(toFile: repo + "/kept.txt", atomically: true, encoding: .utf8)          // changed, not staged
    try "new\n".write(toFile: repo + "/staged.txt", atomically: true, encoding: .utf8); try git(["add", "staged.txt"], repo)

    let m = AppModel.shared
    let saved = (m.client, m.repos, m.worktrees)
    defer { (m.client, m.repos, m.worktrees) = saved }
    m.client = c; m.repos = [r]; m.worktrees = [wt]
    let vc = SourceControlController()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700), styleMask: [.titled], backing: .buffered, defer: true)   // never shown
    window.contentViewController = vc
    vc.view.layoutSubtreeIfNeeded()
    vc.bind(wt.id)
    let outline = try #require(outlines(in: vc.view).first)
    func rows() -> [String] { (0..<outline.numberOfRows).flatMap { (outline.view(atColumn: 0, row: $0, makeIfNecessary: true)).map(texts) ?? [] } }
    for _ in 0..<100 where !rows().contains("staged.txt") { try await Task.sleep(for: .milliseconds(50)) }
    let shown = rows()
    #expect(shown.contains("staged.txt") && shown.contains("kept.txt"), "\(shown)")
    #expect(shown.contains { $0.localizedCaseInsensitiveContains("Staged") })   // its section header
    let staged = try #require(shown.firstIndex(of: "staged.txt")), changed = try #require(shown.firstIndex(of: "kept.txt"))
    #expect(staged < changed)   // staged first, then the rest, as VS Code lists them
}
}
