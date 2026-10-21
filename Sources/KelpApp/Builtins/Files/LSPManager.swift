import AppKit
import Core
import WorkbenchKit

/// The app's side of language servers, which run in the daemon (one per project and server command, shared by every
/// client, stopped once no file is open for it). Which server a file gets comes from the extensions' `languages`; whether
/// a project may run one is the user's say, asked here once per project and checked again by the daemon.
@MainActor
final class LSPManager {
    static let shared = LSPManager()
    /// Server commands already reported missing this launch.
    private var reported: Set<String> = []
    var enabled: Bool { SettingsStore.shared.bool("editor.lsp") != false }

    func language(_ path: String) -> LanguageSpec? { LanguageSpec.find(path, in: ExtensionRegistry.shared.all.languages) }

    // Language servers run the project's own code — build scripts and proc macros (rust-analyzer), Package.swift
    // (sourcekit-lsp), the TypeScript in its node_modules — and formatters can (rustup takes the toolchain a repo's
    // rust-toolchain.toml names), so both run only in a project the user trusted for them, as VS Code's Workspace Trust
    // does: a cloned repository's files don't act as the user just by being opened or formatted.

    /// Projects whose language servers may run (the daemon's UI state: one list per KELP_HOME).
    static let trustKey = LSPOpen.trustKey
    /// The scratch desk too is asked about once: something cloned into it is someone else's code like any other.
    func trusted(_ root: String) -> Bool { UIState.strings(Self.trustKey).contains(root) }
    /// Roots asked about this run, and what starts once the user trusts them (the tabs that wanted a server).
    private var waiting: [String: [@MainActor () -> Void]] = [:]

    /// Language servers on, and `root` trusted; else `start` runs once the user trusts it (`askTrust`).
    func whenTrusted(_ root: String, _ start: @escaping @MainActor () -> Void) -> Bool {
        enabled && askTrust(root, start)
    }

    /// True when `root` is trusted to run its own code; else `then` runs once the user trusts it, asked once per project
    /// per run (a banner with Trust).
    func askTrust(_ root: String, _ then: @escaping @MainActor () -> Void) -> Bool {
        if trusted(root) { return true }
        let start = then
        let first = waiting[root] == nil
        waiting[root, default: []].append(start)
        if first {
            let name = (root as NSString).lastPathComponent
            Banner.show(String(localized: "Language servers and formatters can run code from “\(name)” (its build scripts, plugins, toolchain). Trust this project?"),
                        action: (String(localized: "Trust"), { Task { await LSPManager.shared.trust(root) } }))
        }
        return false
    }

    /// Recorded by the daemon first (a refusal shows, and nothing starts), then the tabs waiting for it start.
    func trust(_ root: String) async {
        if !trusted(root) {
            guard await UIState.save(Self.trustKey, .array((UIState.strings(Self.trustKey) + [root]).map(JSONValue.string))) else { return }
        }
        (waiting.removeValue(forKey: root) ?? []).forEach { $0() }
    }

    /// Gives a file a tab shows to its server, which the daemon starts when it isn't running. False when there's none: no
    /// server for its language, servers off, or refused — the daemon's reason shows (trust the project, install the server;
    /// `retry` runs once the user trusts it).
    func open(root: String, path: String, text: String, retry: @escaping @MainActor () -> Void) async -> Bool {
        guard enabled, let lang = language(path), let server = lang.server else { return false }
        do {
            _ = try await AppModel.shared.get(LSPOpen(root: root, path: path, languageId: lang.id, command: server.command, args: server.args, text: text))
            return true
        } catch {
            switch LSPRefusal(error) {
            case .untrusted?: _ = askTrust(root, retry)   // the daemon doesn't have it as trusted (another copy of Kelp recorded it)
            case .notInstalled?: reportMissing(server)
            case nil: break   // no daemon now: a reconnect opens it again
            }
            return false
        }
    }

    /// The file's whole text, as typed (in order: notifications on one connection).
    func change(root: String, path: String, text: String) { AppModel.shared.client?.notify(LSPChange(root: root, path: path, text: text)) }
    func close(root: String, path: String) { AppModel.shared.client?.notify(LSPClose(root: root, path: path)) }

    /// Completions at a 1-based position; none when the server can't say (quietly: they're offered while typing).
    func completion(root: String, path: String, line: Int, column: Int) async -> [CodeCompletion] {
        await AppModel.shared.quiet(LSPCompletion(root: root, path: path, line: line, column: column)) ?? []
    }
    func definition(root: String, path: String, line: Int, column: Int) async -> CodeLocation? {
        await AppModel.shared.quiet(LSPDefinition(root: root, path: path, line: line, column: column)) ?? nil
    }
    func symbol(root: String, path: String, line: Int) async -> String? {
        await AppModel.shared.quiet(LSPSymbol(root: root, path: path, line: line)) ?? nil
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
