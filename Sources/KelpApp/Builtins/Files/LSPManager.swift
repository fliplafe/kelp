import AppKit
import Core
import LSPKit
import WorkbenchKit

/// Lazily starts one language server per (worktree, server command). Which server a file gets comes from the
/// extensions' `languages`. A server that died is started again on next use (its open files with it), at most
/// once per `retryDelay`; one with no open file for a minute is stopped.
@MainActor
final class LSPManager {
    static let shared = LSPManager()
    private var clients: [String: LSPClient] = [:]
    private var starting: [String: Task<LSPClient?, Never>] = [:]
    /// When each server was last started: a broken one isn't respawned on every edit.
    private var started: [String: Date] = [:]
    private static let retryDelay: TimeInterval = 30
    /// Server commands already reported missing this launch.
    private var reported: Set<String> = []
    var enabled: Bool { SettingsStore.shared.bool("editor.lsp") != false }

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LSPManager.shared.clients.values.forEach { $0.terminate() } }
        }
    }

    func language(_ path: String) -> LanguageSpec? { LanguageSpec.find(path, in: ExtensionRegistry.shared.all.languages) }

    func client(root: String, path: String) async -> LSPClient? {
        guard enabled, let lang = language(path), let server = lang.server else { return nil }
        let argv = [server.command] + (server.args ?? [])
        let key = root + "|" + argv.joined(separator: " ")
        if let c = clients[key], c.isRunning { return c }
        if let t = starting[key] { return await t.value }
        if let at = started[key], Date().timeIntervalSince(at) < Self.retryDelay { return nil }
        let reopen = clients[key]?.openDocuments ?? [:]   // a server that died: its files go to the new one
        started[key] = Date()
        let t = Task<LSPClient?, Never> { @MainActor in
            // The login-shell PATH may still be loading: look the command up off the main thread.
            let cmd = server.command
            guard await Task.detached(operation: { (try? LoginPath.resolve(cmd)) != nil }).value else { reportMissing(server); return nil }
            guard let c = LSPClient(argv: argv, root: root) else { return nil }
            c.onIdle = { Task { @MainActor in LSPManager.shared.stopWhenIdle(key) } }
            do { try await c.initialize() } catch { return nil }
            for (p, n) in reopen {
                let text = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
                for _ in 0..<n { c.open(p, text: text, languageId: language(p)?.id ?? lang.id) }
            }
            return c
        }
        starting[key] = t
        let c = await t.value
        starting[key] = nil
        if let c { clients[key] = c }   // else keep the dead one: its open files go to the next try
        stopWhenIdle(key)   // started only to close a file, say
        return c
    }

    /// Stops the server a minute from now if it still has no open file then (its project's tabs were closed).
    private func stopWhenIdle(_ key: String) {
        Task {
            try? await Task.sleep(for: .seconds(60))
            guard let c = clients[key], c.isIdle else { return }
            clients[key] = nil; started[key] = nil; c.shutdown()
        }
    }

    /// Once per command and launch; the button runs the language's `install` in a terminal tab.
    private func reportMissing(_ server: LanguageSpec.Server) {
        guard reported.insert(server.command).inserted else { return }
        let name = server.command
        Banner.show(String(localized: "Language server \(name) isn't installed."), action: server.install.map { cmd in
            (String(localized: "Install"), { Workbench.editor?.run(command: cmd, title: String(localized: "Install \(name)")) })
        })
    }
}
