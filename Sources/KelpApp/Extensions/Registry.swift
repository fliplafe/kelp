import AppKit
import SwiftUI
import Core
import Agents
import WorkbenchKit

/// What the IDE knows when a contribution runs: the workspace on screen and what has focus.
@MainActor
struct IDEContext {
    var workspace: Worktree?
    var project: Repo?
    var focusedFile: String?

    static var current: IDEContext {
        let w = AppModel.shared.worktree(Workbench.shared.workspaceId)
        return IDEContext(workspace: w, project: AppModel.shared.repo(w?.repoId),
                          focusedFile: Workbench.shared.focusedFile)
    }
}

/// A right-inspector panel.
struct PanelSpec: Identifiable {
    let id: String, title: String, icon: String, extensionId: String
    /// A number on the panel's icon (0: none). Read under observation, so it must not build the panel.
    var badge: (@MainActor () -> Int)?
    let make: @MainActor () -> NSViewController
}

/// An entry of the editor area's "+" menu. `open` runs only when chosen (it may ask questions, start things…).
struct EditorSpec: Identifiable {
    let id: String, title: String, icon: String, extensionId: String
    let open: @MainActor (IDEContext) -> Void

    /// The common case: the entry opens a tab for a URI.
    init(id: String, title: String, icon: String, extensionId: String, uri: @escaping @MainActor (IDEContext) -> String?) {
        self.id = id; self.title = title; self.icon = icon; self.extensionId = extensionId
        open = { ctx in if let u = uri(ctx) { Workbench.open(u) } }
    }
}

/// An action with a stable id, the one thing the menu bar, key bindings (settings.json `keys`), the command palette
/// and agents (`kelp run <id>`) call.
struct CommandSpec: Identifiable {
    let id: String, title: String, extensionId: String
    var key: String?
    /// The menu bar menu it goes in when Kelp's own layout (`AppDelegate.buildMenu`) doesn't place it; nil: Tools.
    var menu: String?
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

/// A file icon theme in VS Code's format (see IconTheme).
struct IconThemeSpec {
    let id: String, label: String, file: URL
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
    var iconThemes: [IconThemeSpec] = []
    var agents: [AgentManifest] = []
    var tabs: [TabProvider] = []
    /// In load order: `LanguageSpec.find` lets a later one replace an earlier one with the same id.
    var languages: [LanguageSpec] = []
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
}

/// The IDE is a shell around this: everything visible comes from an extension, built-in or a folder in ~/.kelp/extensions.
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

    /// Built-ins a clean install starts with switched off; once settings.json has its own list, that list decides.
    static let offByDefault: Set<String> = ["kelp.activity"]
    static func disabled(_ v: JSONValue?) -> Set<String> { v?.array.map { Set($0.compactMap(\.string)) } ?? offByDefault }
    var disabled: Set<String> { Self.disabled(SettingsStore.shared.value("extensions.disabled")) }

    func reload() {
        var infos: [ExtensionInfo] = []
        var merged = Contributions()
        let off = disabled
        disabledLoaded = off
        DeclarativeExtension.forget()
        func take(_ info: ExtensionInfo, _ c: Contributions) {
            var info = info; info.enabled = info.essential || !off.contains(info.id)
            infos.append(info)
            guard info.enabled else { DeclarativeExtension.forget(info.id); return }
            merged.panels += c.panels; merged.editors += c.editors; merged.commands += c.commands
            merged.settings += c.settings; merged.themes += c.themes; merged.iconThemes += c.iconThemes; merged.agents += c.agents; merged.tabs += c.tabs
            merged.languages += c.languages
        }
        for b in Builtins.all { take(b.info, b.contribute()) }
        // Requirement checks need the login-shell PATH; until it's read (in the background) assume tools are there.
        for folder in (try? FileManager.default.contentsOfDirectory(at: Self.userDir, includingPropertiesForKeys: nil)) ?? [] where Self.isFolder(folder) {
            let loaded = DeclarativeExtension.load(folder, checkRequirements: Self.pathReady)
            take(loaded.info, loaded.contributions)
        }
        merged.tabs.append(DeclarativeExtension.tabProvider)
        extensions = infos.sorted { ($0.builtin ? 0 : 1, $0.name) < ($1.builtin ? 0 : 1, $1.name) }
        all = merged
        revision += 1
        ThemeManager.shared.apply()
        AgentSkills.write()
        AppModel.shared.publishUIState()
    }

    /// Live reload while someone (often an agent) edits an extension.
    func watch() {
        try? FileManager.default.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        let pending = Debounce()
        watcher = FileWatcher(root: Self.userDir.path) { [weak self] _ in pending.after(0.3) { self?.reload() } }
    }

    /// Follows symlinks: a VS Code extension can be linked in rather than copied.
    /// One folder name and nothing more: not empty, no "/", not "." or "..", not hidden.
    nonisolated static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\0") && !name.hasPrefix(".") && name.count <= 255
    }

    private static func isFolder(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
    }

    /// Like VS Code's "Install from VSIX…": a .vsix (a zip with the extension in `extension/`) or an extension folder,
    /// copied into ~/.kelp/extensions. A version already there goes to the Trash.
    func install(_ src: URL) async throws {
        let dir = Self.userDir
        try await Task.detached {
            let fm = FileManager.default
            var folder = src, name = src.lastPathComponent
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: tmp) }
            if src.pathExtension.lowercased() == "vsix" {
                let unzip = await Shell.exec(["/usr/bin/ditto", "-x", "-k", src.path, tmp.path])
                folder = tmp.appendingPathComponent("extension")
                guard unzip.code == 0, fm.fileExists(atPath: folder.appendingPathComponent("package.json").path) else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: src.path])
                }
                name = (try? JSONDecoder().decode(VSCodePackage.self, from: Data(contentsOf: folder.appendingPathComponent("package.json"))).manifest.id)
                    ?? src.deletingPathExtension().lastPathComponent
            }
            // The id names a folder inside ~/.kelp/extensions: "..", "a/b" or ".hidden" would point somewhere else (".." is
            // ~/.kelp itself, which the line below would send to the Trash).
            guard Self.isPlainName(name) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: src.path]) }
            let dest = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: folder, to: dest)
        }.value
        reload()
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
        if scheme == "ext", DeclarativeExtension.viewInfo(uri) == nil { return nil }   // its extension is off or gone
        return all.tabs.first { $0.schemes.contains(scheme) }
    }

    func command(_ id: String) -> CommandSpec? { all.commands.first { $0.id == id } }
}
