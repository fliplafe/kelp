import AppKit
import Core
import TerminalKit
import EditorKit

/// A color theme: terminal and editor colors, optionally tied to light or dark appearance.
struct Theme: Codable, Identifiable, Equatable {
    struct TerminalColors: Codable, Equatable {
        var background: String, foreground: String
        var cursor: String?, selection: String?
        var palette: [String]?
    }
    struct EditorColors: Codable, Equatable {
        var background: String, text: String
        var keyword: String?, string: String?, comment: String?, type: String?, number: String?, function: String?
        var selection: String?, lineHighlight: String?
    }
    var id: String
    var name: String
    var appearance: String?      // "light" / "dark" / nil (either)
    var terminal: TerminalColors?
    var editor: EditorColors?
}

/// Applies the chosen theme and fonts to the window, terminals and editors whenever settings change.
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()
    private var lastTerminal: TerminalAppearance?
    private var appearanceObserver: NSKeyValueObservation?

    static let builtin: [Theme] = [
        Theme(id: "krill.light", name: "Krill Light", appearance: "light",
              terminal: .init(background: "#ffffff", foreground: "#1d1d1f", cursor: "#0a84ff", selection: "#b3d7ff",
                              palette: ["#1d1d1f", "#c41a16", "#007400", "#826b28", "#0b4f79", "#9b2393", "#326d74", "#8e8e93",
                                        "#636366", "#e0362e", "#28a745", "#b28600", "#0a84ff", "#bf5af2", "#3a9bae", "#1d1d1f"]),
              editor: nil),
        Theme(id: "krill.dark", name: "Krill Dark", appearance: "dark",
              terminal: .init(background: "#1e1e22", foreground: "#e5e5ea", cursor: "#0a84ff", selection: "#3a4a63",
                              palette: ["#2c2c30", "#ff6b6b", "#7ee787", "#e3c26a", "#6cb6ff", "#d2a8ff", "#5dd8e0", "#c7c7cc",
                                        "#636366", "#ff8a80", "#97f3a0", "#f2d58a", "#8cc8ff", "#e0bfff", "#87e5ec", "#ffffff"]),
              editor: .init(background: "#1e1e22", text: "#e5e5ea", keyword: "#ff7ab2", string: "#ff8170", comment: "#7f8c98",
                            type: "#5dd8ff", number: "#d9c97c", function: "#67b7a4")),
        Theme(id: "dracula", name: "Dracula", appearance: "dark",
              terminal: .init(background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2", selection: "#44475a",
                              palette: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                                        "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
              editor: .init(background: "#282a36", text: "#f8f8f2", keyword: "#ff79c6", string: "#f1fa8c", comment: "#6272a4",
                            type: "#8be9fd", number: "#bd93f9", function: "#50fa7b"))
    ]

    /// "auto" follows macOS light/dark; "ghostty" leaves the terminal to ~/.config/ghostty.
    var themes: [Theme] { Self.builtin + Theme.popular + ExtensionRegistry.shared.all.themes }

    var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func apply() {
        let s = SettingsStore.shared
        // A theme with its own look (Krill Light, Dracula…) sets the whole window's, like VS Code;
        // "Appearance" decides for Auto and Ghostty, which have none.
        let themeLook = themes.first { $0.id == s.string("workbench.theme") }?.appearance
        let want: NSAppearance.Name? = switch themeLook ?? s.string("workbench.appearance") ?? "system" {
        case "light": .aqua
        case "dark": .darkAqua
        default: nil
        }
        if NSApp.appearance?.name != want { NSApp.appearance = want.flatMap { NSAppearance(named: $0) } }
        if appearanceObserver == nil {
            // macOS switched light/dark: "auto" themes follow (colors only; setting the appearance here would loop).
            appearanceObserver = NSApp.observe(\.effectiveAppearance) { _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { ThemeManager.shared.applyColors() } }
            }
        }
        applyColors()
    }

    func applyColors() {
        let s = SettingsStore.shared
        let id = s.string("workbench.theme") ?? "auto"
        let theme: Theme? = id == "ghostty" ? nil : themes.first { $0.id == (id == "auto" ? (isDark ? "krill.dark" : "krill.light") : id) }

        var t = TerminalAppearance()
        t.useGhosttyConfig = theme == nil || s.bool("terminal.useGhosttyConfig") == true
        if let c = theme?.terminal {
            t.background = c.background; t.foreground = c.foreground; t.cursor = c.cursor; t.selection = c.selection; t.palette = c.palette ?? []
        }
        t.fontFamily = s.string("terminal.fontFamily").flatMap { $0.isEmpty ? nil : $0 }
        t.fontSize = s.number("terminal.fontSize")
        t.cursorStyle = s.string("terminal.cursorStyle")
        t.optionAsAlt = s.bool("terminal.optionAsAlt") ?? false
        if t != lastTerminal {
            lastTerminal = t
            #if canImport(GhosttyKit)
            GhosttyRuntime.appearance = t
            if GhosttyTerminalView.isLoaded { GhosttyRuntime.shared.configure(t) }
            #endif
        }

        let e = theme?.editor
        let palette = e.map { CodeEditor.Palette(background: $0.background, text: $0.text, keyword: $0.keyword, string: $0.string, comment: $0.comment,
                                                 type: $0.type, number: $0.number, function: $0.function, selection: $0.selection, lineHighlight: $0.lineHighlight) }
        let size = CGFloat(s.number("editor.fontSize") ?? 13), font = s.string("editor.fontFamily").flatMap { $0.isEmpty ? nil : $0 }
        let minimap = s.bool("editor.minimap") ?? false
        if palette != CodeEditor.palette || size != CodeEditor.fontSize || font != CodeEditor.fontName || minimap != CodeEditor.showMinimap {
            CodeEditor.palette = palette; CodeEditor.fontSize = size; CodeEditor.fontName = font; CodeEditor.showMinimap = minimap
            NotificationCenter.default.post(name: .krillAppearance, object: nil)
        }
    }
}

extension Notification.Name { static let krillAppearance = Notification.Name("krill.appearance") }
