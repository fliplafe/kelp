import Foundation
import Observation
import LSPKit

/// Lazily starts one language server per (worktree, language) and keeps diagnostics per file (observable).
@MainActor
@Observable
final class LSPManager {
    static let shared = LSPManager()
    @ObservationIgnored private var clients: [String: LSPClient] = [:]
    @ObservationIgnored private var starting: [String: Task<LSPClient?, Never>] = [:]
    private(set) var diagnostics: [String: [Diagnostic]] = [:]   // absolute path -> list
    var enabled: Bool { SettingsStore.shared.bool("editor.lsp") != false }

    func client(root: String, path: String) async -> LSPClient? {
        guard enabled, let spec = LSPServers.byExtension[(path as NSString).pathExtension] else { return nil }
        let key = root + "|" + spec.id
        if let c = clients[key] { return c }
        if let t = starting[key] { return await t.value }
        let t = Task<LSPClient?, Never> { @MainActor in
            guard let c = LSPClient(argv: spec.argv, root: root) else { return nil }
            c.onDiagnostics = { p, d in Task { @MainActor in LSPManager.shared.diagnostics[p] = d } }
            do { try await c.initialize() } catch { return nil }
            return c
        }
        starting[key] = t
        let c = await t.value
        starting[key] = nil; clients[key] = c
        return c
    }
}
