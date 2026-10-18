import AppKit
import SwiftUI
import Core
import Agents

/// What the IDE knows when a contribution runs: the workspace on screen and what has focus.
@MainActor
struct IDEContext {
    var workspace: Worktree?
    var project: Repo?
    var focusedSession: String?
    var focusedFile: String?

    static var current: IDEContext {
        let w = AppModel.shared.worktree(Workbench.shared.workspaceId)
        return IDEContext(workspace: w, project: AppModel.shared.repo(w?.repoId),
                          focusedSession: Workbench.shared.focusedSession, focusedFile: Workbench.shared.focusedFile)
    }
}

/// A right-inspector panel.
struct PanelSpec: Identifiable {
    let id: String, title: String, icon: String, extensionId: String
    let make: @MainActor () -> NSViewController
}

/// An entry of the editor area's "+" menu: opening it opens `uri`.
struct EditorSpec: Identifiable {
    let id: String, title: String, icon: String, extensionId: String
    let uri: @MainActor (IDEContext) -> String?
}

/// Command palette entry.
struct CommandSpec: Identifiable {
    let id: String, title: String, extensionId: String
    var key: String?
    let run: @MainActor ([String: JSONValue]) -> Void
}

/// One setting in Settings and settings.json.
struct SettingSpec: Codable, Identifiable {
    var key: String
    var title: String
    var type: String            // boolean · number · string · enum · color · font
    var `default`: JSONValue?
    var description: String?
    var options: [String]?
    var id: String { key }
}

struct SettingsSection: Identifiable {
    let id: String, title: String, icon: String, extensionId: String
    var specs: [SettingSpec]
    /// Optional custom UI under the generated rows (accounts, integrations…).
    var custom: (@MainActor () -> AnyView)?
}

/// Opens tabs for URIs of a scheme ("session", "file", "https"…).
struct TabProvider {
    let schemes: [String], extensionId: String
    let make: @MainActor (String) -> TabContent?
}

/// Everything one extension adds. Built-ins fill it in Swift; folders from extension.json.
struct Contributions {
    var panels: [PanelSpec] = []
    var editors: [EditorSpec] = []
    var commands: [CommandSpec] = []
    var settings: [SettingsSection] = []
    var themes: [Theme] = []
    var agents: [AgentManifest] = []
    var tabs: [TabProvider] = []
}

struct ExtensionInfo: Identifiable {
    let id: String, name: String, description: String, version: String, icon: String
    let builtin: Bool
    /// Can't be turned off (the IDE needs it).
    var essential = false
    var path: URL?
    var error: String?
    /// A required tool is missing; shown, but contributes nothing.
    var unavailable: String?
    var enabled: Bool
    var removable: Bool { !builtin }
}

/// The IDE is a shell around this: everything visible comes from an extension, built-in or a folder in ~/.krill/extensions.
@MainActor
@Observable
final class ExtensionRegistry {
    static let shared = ExtensionRegistry()
    private(set) var extensions: [ExtensionInfo] = []
    private(set) var all = Contributions()
    /// Bumped on every reload so views can refresh.
    private(set) var revision = 0
    private(set) var disabledLoaded: Set<String> = []
    @ObservationIgnored private var watcher: FileWatcher?

    static var userDir: URL { Paths.root.appendingPathComponent("extensions") }
    /// Set once LoginPath has been read off the main thread.
    static var pathReady = false

    var disabled: Set<String> { Set((SettingsStore.shared.value("extensions.disabled")?.array ?? []).compactMap(\.string)) }

    func reload() {
        var infos: [ExtensionInfo] = []
        var merged = Contributions()
        let off = disabled
        disabledLoaded = off
        func take(_ info: ExtensionInfo, _ c: Contributions) {
            var info = info; info.enabled = info.essential || !off.contains(info.id)
            infos.append(info)
            guard info.enabled else { return }
            merged.panels += c.panels; merged.editors += c.editors; merged.commands += c.commands
            merged.settings += c.settings; merged.themes += c.themes; merged.agents += c.agents; merged.tabs += c.tabs
        }
        for b in Builtins.all { take(b.info, b.contribute()) }
        // Requirement checks need the login-shell PATH; until it's read (in the background) assume tools are there.
        for folder in BundledExtensions.materialize() {
            let loaded = DeclarativeExtension.load(folder, builtin: true, checkRequirements: Self.pathReady)
            take(loaded.info, loaded.contributions)
        }
        for folder in (try? FileManager.default.contentsOfDirectory(at: Self.userDir, includingPropertiesForKeys: nil)) ?? [] where folder.hasDirectoryPath {
            let loaded = DeclarativeExtension.load(folder, checkRequirements: Self.pathReady)
            take(loaded.info, loaded.contributions)
        }
        merged.tabs.append(DeclarativeExtension.tabProvider)
        extensions = infos.sorted { ($0.builtin ? 0 : 1, $0.name) < ($1.builtin ? 0 : 1, $1.name) }
        all = merged
        revision += 1
        ThemeManager.shared.apply()
        AppModel.shared.publishUIState()
    }

    /// Live reload while someone (often an agent) edits an extension.
    func watch() {
        try? FileManager.default.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        let guide = Self.userDir.appendingPathComponent("EXTENSIONS.md")
        if (try? String(contentsOf: guide, encoding: .utf8)) != ExtensionGuide.markdown { try? ExtensionGuide.markdown.write(to: guide, atomically: true, encoding: .utf8) }
        var pending: DispatchWorkItem?
        watcher = FileWatcher(root: Self.userDir.path) { [weak self] _ in
            pending?.cancel()
            let w = DispatchWorkItem { self?.reload() }
            pending = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        var off = disabled
        if on { off.remove(id) } else { off.insert(id) }
        SettingsStore.shared.set("extensions.disabled", .array(off.sorted().map { .string($0) }))
    }

    func uninstall(_ id: String) {
        guard let e = extensions.first(where: { $0.id == id }), let path = e.path, !e.builtin else { return }
        try? FileManager.default.trashItem(at: path, resultingItemURL: nil)
        reload()
    }

    func tabProvider(for uri: String) -> TabProvider? {
        let scheme = TabURI.scheme(uri)
        return all.tabs.first { $0.schemes.contains(scheme) }
    }

    func command(_ id: String) -> CommandSpec? { all.commands.first { $0.id == id } }
}
