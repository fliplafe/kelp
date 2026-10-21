import AppKit
import Foundation
import Testing
import TestSupport
import Core
import GitKit
import Daemon
@testable import KelpApp

/// KelpApp code reads `Paths` (scratch, extensions, skills) and agents' folders: the process is isolated (TestIsolation).
let testHome: String = { _ = TestIsolation.root; return String(cString: getenv("KELP_HOME")) }()

/// Tests that point `AppModel.shared` at a daemon of their own: one at a time, or one would swap the other's client.
@Suite(.serialized) @MainActor struct SharedAppModel {}

/// A daemon of the test's own in a short temp folder (its socket path must fit 104 bytes), a git repository with `files`
/// committed and added as its project, and `AppModel.shared` / `Workbench.shared` pointed at both. `done()` puts back
/// what was there, stops the daemon and removes the folder.
@MainActor
final class AppRig {
    let root: URL, daemon: Daemon, client: RPCClient
    let repo: String, project: Repo, workspace: Worktree
    private let saved: (RPCClient?, [Repo], [Worktree], String?)
    private var windows: [NSWindow] = []

    init(files: [String: String] = ["f.txt": "a\n"]) async throws {
        _ = testHome
        root = URL(fileURLWithPath: "/tmp/kr-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        daemon = try Daemon(root: root); try daemon.start()
        client = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
        repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for a in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] { try Git.run(a, cwd: repo) }
        for (name, text) in files { try text.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8) }
        if !files.isEmpty { try Git.run(["add", "."], cwd: repo); try Git.run(["commit", "-qm", "init"], cwd: repo) }
        project = try await client.call(RepoAdd(path: repo))
        guard let w = try await client.call(WorktreeList(repoId: project.id)).first else { throw RPCError.internalError("no workspace") }
        workspace = w
        let m = AppModel.shared, wb = Workbench.shared
        saved = (m.client, m.repos, m.worktrees, wb.workspaceId)
        m.client = client; m.repos = [project]; m.worktrees = [workspace]; wb.workspaceId = workspace.id
    }

    func write(_ name: String, _ text: String) throws { try text.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8) }
    func git(_ args: String...) throws { try Git.run(args, cwd: repo) }

    /// `vc` in a window that's never shown, at that size, kept until `done()`.
    func show(_ vc: NSViewController, _ w: CGFloat, _ h: CGFloat) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentViewController = vc
        windows.append(window)
    }

    func done() {
        let m = AppModel.shared
        (m.client, m.repos, m.worktrees, Workbench.shared.workspaceId) = saved
        daemon.stop()
        try? FileManager.default.removeItem(at: root)
    }
}
