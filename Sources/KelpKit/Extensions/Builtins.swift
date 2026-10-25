import AppKit
import SwiftUI
import Core
import Agents
import WorkbenchKit

/// A built-in extension: same contribution points as an extension.json folder, implemented in Swift.
@MainActor
package struct Builtin {
    let info: ExtensionInfo
    /// What it adds to `app`: its tabs, panels and commands are made with it.
    let contribute: @MainActor (_ app: AppModel) -> Contributions

    package init(_ id: String, _ name: String, _ description: String, icon: String, essential: Bool = false,
                 _ contribute: @escaping @MainActor (_ app: AppModel) -> Contributions) {
        info = ExtensionInfo(id: id, name: name, description: description, version: "built-in", icon: icon, builtin: true, essential: essential, enabled: true)
        self.contribute = contribute
    }
}

@MainActor
package enum Builtins {
    /// A command that takes no arguments.
    package static func cmd(_ id: String, _ title: String, _ key: String? = nil, _ run: @escaping @MainActor () -> Void) -> CommandSpec {
        CommandSpec(id: id, title: title, key: key) { _ in run() }
    }
    /// The editor area on screen; a beep when there is none.
    package static func editor(_ app: AppModel) -> EditorArea? {
        if app.workbench.editor == nil { NSSound.beep() }
        return app.workbench.editor
    }

    package static func s(_ key: String, _ title: String, _ type: String, _ def: JSONValue?, _ desc: String? = nil, options: [String]? = nil,
                          group: String? = nil) -> SettingSpec {
        SettingSpec(key: key, title: title, type: type, default: def, description: desc, options: options, group: group)
    }

    package static let appearance = Builtin("kelp.appearance", "Appearance", "Themes for the window, terminal and editor.",
                                            icon: "paintpalette", essential: true) { _ in
        var c = Contributions()
        c.settings = [SettingsSection(id: "appearance", title: "Appearance", icon: "paintpalette", specs: [
            s("workbench.theme", "Color Theme", "theme", "auto",
              "The window, terminal and editor together. Match System switches Kelp Light / Dark with macOS; Ghostty keeps your Ghostty terminal colors."),
            s("workbench.iconTheme", "File Icon Theme", "enum", .string(FileIcon.system),
              "Icons in Files, Source Control and tabs. VS Code icon themes work as they are: Settings › Extensions › Install…"),
            s("workbench.inspectorIcons", "Inspector icons", "enum", "center", "Where the panel icons sit in their row.",
              options: ["left", "center", "right"]),
            s("workbench.inspectorIconsPosition", "Inspector icons position", "enum", "top",
              "Level with the tabs or under the panel. Drag an icon to move it; right-click the icons to hide them.",
              options: ["top", "bottom"]),
            s("workbench.inspector.autoHide", "Auto-hide inspector", "boolean", false, "Comes in while the pointer is at the window's right edge."),
            s("workbench.sideBySideButton", "Agents Side by Side button", "boolean", true,
              "In the title bar, right of the search; right-click it to hide it. ⌃⌘T works either way.")
        ] + sidebar), SettingsSection(id: "keyboard", title: "Keyboard", icon: "keyboard", specs: [],
                            custom: { AnyView(KeyboardSettings()) })]
        return c
    }

    /// Appearance › Sidebar: what people see differently in the list, each read where the sidebar draws it.
    private static let sidebar = [
        s("workbench.sidebar.autoHide", "Auto-hide sidebar", "boolean", false, "Comes in while the pointer is at the window's left edge, like the Dock.",
          group: "Sidebar"),
        s("workbench.textSize", "Text size", "enum", "normal", "Sidebar and inspector. The terminal and the editor have their own font sizes.",
          options: ["normal", "large", "larger"], group: "Sidebar")
    ]
}
