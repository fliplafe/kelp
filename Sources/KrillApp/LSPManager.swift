import Foundation
import LSPKit

/// Lazily starts one language server per (worktree, language) and keeps diagnostics per file.
@MainActor
final class LSPManager {
    static let shared = LSPManager()
    private var clients: [String: LSPClient] = [:]
    private var starting: [String: Task<LSPClient?, Never>] = [:]
    private(set) var diagnostics: [String: [Diagnostic]] = [:]   // absolute path -> list
    var onDiagnostics: ((String) -> Void)?
    var enabled: Bool { UserDefaults.standard.object(forKey: "lspEnabled") as? Bool ?? true }

    func client(root: String, path: String) async -> LSPClient? {
        guard enabled, let spec = LSPServers.byExtension[(path as NSString).pathExtension] else { return nil }
        let key = root + "|" + spec.id
        if let c = clients[key] { return c }
        if let t = starting[key] { return await t.value }
        let t = Task<LSPClient?, Never> { @MainActor in
            guard let c = LSPClient(argv: spec.argv, root: root) else { return nil }
            c.onDiagnostics = { p, d in Task { @MainActor in LSPManager.shared.diagnostics[p] = d; LSPManager.shared.onDiagnostics?(p) } }
            do { try await c.initialize() } catch { return nil }
            return c
        }
        starting[key] = t
        let c = await t.value
        starting[key] = nil; clients[key] = c
        return c
    }
}
