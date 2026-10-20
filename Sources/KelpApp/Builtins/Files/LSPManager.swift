import Foundation
import Observation
import Core
import LSPKit
import WorkbenchKit

/// Lazily starts one language server per (worktree, server command) and keeps diagnostics per file (observable).
/// Which server a file gets comes from the extensions' `languages`.
@MainActor
@Observable
final class LSPManager {
    static let shared = LSPManager()
    @ObservationIgnored private var clients: [String: LSPClient] = [:]
    @ObservationIgnored private var starting: [String: Task<LSPClient?, Never>] = [:]
    /// Server commands already reported missing this launch.
    @ObservationIgnored private var reported: Set<String> = []
    private(set) var diagnostics: [String: [Diagnostic]] = [:]   // absolute path -> list
    var enabled: Bool { SettingsStore.shared.bool("editor.lsp") != false }

    func language(_ path: String) -> LanguageSpec? { LanguageSpec.find(path, in: ExtensionRegistry.shared.all.languages) }

    func client(root: String, path: String) async -> LSPClient? {
        guard enabled, let lang = language(path), let server = lang.server else { return nil }
        let argv = [server.command] + (server.args ?? [])
        let key = root + "|" + argv.joined(separator: " ")
        if let c = clients[key] { return c }
        if let t = starting[key] { return await t.value }
        let t = Task<LSPClient?, Never> { @MainActor in
            // The login-shell PATH may still be loading: look the command up off the main thread.
            let cmd = server.command
            guard await Task.detached(operation: { (try? LoginPath.resolve(cmd)) != nil }).value else { reportMissing(server); return nil }
            guard let c = LSPClient(argv: argv, root: root) else { return nil }
            c.onDiagnostics = { p, d in Task { @MainActor in LSPManager.shared.diagnostics[p] = d } }
            do { try await c.initialize() } catch { return nil }
            return c
        }
        starting[key] = t
        let c = await t.value
        starting[key] = nil; clients[key] = c
        return c
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
