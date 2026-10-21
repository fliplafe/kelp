import AppKit
import UniformTypeIdentifiers

/// The icon beside a file or folder name (Files, Source Control, tabs, Quick Open), from the theme picked in
/// Settings › Appearance: System (Finder's icons, the default), Colorful, or a VS Code icon theme an extension adds.
@MainActor
enum FileIcon {
    static let system = "default", colorful = "kelp.colorful"

    /// The choices for `workbench.iconTheme`.
    static var themes: [(id: String, label: String)] {
        [(system, "System"), (colorful, "Colorful")] + ExtensionRegistry.shared.all.iconThemes.map { ($0.id, $0.label) }
    }

    /// Changes with the pick and with installed extensions: views showing icons reload when it does.
    static var revision: String { "\(SettingsStore.shared.string("workbench.iconTheme") ?? system)#\(ExtensionRegistry.shared.revision)" }

    static func image(_ name: String, folder: Bool = false, expanded: Bool = false) -> NSImage {
        switch SettingsStore.shared.string("workbench.iconTheme") ?? system {
        case system: systemIcon(name, folder: folder)
        case colorful: ColorfulIcons.image(name, folder: folder)
        case let id: contributed(id)?.image(name, folder: folder, expanded: expanded) ?? systemIcon(name, folder: folder)
        }
    }

    private static var systemIcons: [String: NSImage] = [:]
    private static func systemIcon(_ name: String, folder: Bool) -> NSImage {
        if folder { return .symbol("folder") }
        let ext = (name as NSString).pathExtension.lowercased()
        if let i = systemIcons[ext] { return i }
        let i = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data).resized(16)
        systemIcons[ext] = i; return i
    }

    private static var loaded: (key: String, theme: IconTheme?)?
    private static func contributed(_ id: String) -> IconTheme? {
        let key = "\(id)#\(ExtensionRegistry.shared.revision)"
        if loaded?.key != key {
            var theme: IconTheme?
            if let spec = ExtensionRegistry.shared.all.iconThemes.first(where: { $0.id == id }) {
                do { theme = try IconTheme(contentsOf: spec.file) }
                catch { Banner.show(String(localized: "File icon theme “\(spec.label)”: \(error.localizedDescription)"), style: .error) }
            }
            loaded = (key, theme)
        }
        return loaded?.theme
    }
}
