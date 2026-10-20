import AppKit
import SwiftUI
import Core

/// Settings › Keyboard: any menu command's shortcut, set by pressing it. The menu is built with Kelp's defaults and
/// then the overrides in settings.json are laid over it: `"keys": {"editor.saveAll": "opt+cmd+s"}` ("" = none).
/// Kelp's commands go by their id; the menu's other items (Copy, Minimize, the agents in New Tab) by their English path.
@MainActor
enum KeyBindings {
    struct Key: Equatable { var key: String; var mods: NSEvent.ModifierFlags }
    struct Entry: Identifiable { let id: String; let menu: String; let title: String; var key: Key?; let defaultKey: Key? }

    /// Each item's default, recorded every time the menu is built (always with the defaults).
    private static var defaults: [String: Key?] = [:]
    private static let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    static var overrides: [String: String] {
        guard case .object(let o)? = SettingsStore.shared.value("keys") else { return [:] }
        return o.compactMapValues(\.string)
    }

    /// Names every item and applies the overrides. Runs while the titles are English.
    static func apply(to menu: NSMenu) {
        var over = overrides, moved = false
        func walk(_ m: NSMenu, _ path: [String]) {
            for i in m.items where !i.isSeparatorItem {
                if let s = i.submenu { if s !== NSApp.servicesMenu { walk(s, path + [i.title]) }; continue }
                guard let action = i.action else { continue }
                // A command's item goes by the command id, the others by their English path ("Edit › Copy").
                let command = action == #selector(AppDelegate.runCommand(_:)), name = i.identifier?.rawValue ?? i.title
                let id = command ? name : (path + [i.title]).joined(separator: " › ")   // English: the same in every language
                // Overrides saved before used AppKit's names for the items, their selectors ("Edit › copy:"): moved once.
                let old = (path + [command ? legacy[id] ?? i.title : name]).joined(separator: " › ")
                if id != old, let v = over.removeValue(forKey: old) { over[id] = over[id] ?? v; moved = true }
                i.identifier = NSUserInterfaceItemIdentifier(id)
                defaults[id] = i.keyEquivalent.isEmpty ? Key?.none : Key(key: i.keyEquivalent, mods: i.keyEquivalentModifierMask.intersection(mask))
                guard let spec = over[id] else { continue }
                let k = spec.isEmpty ? nil : AppDelegate.parseKey(spec)
                i.keyEquivalent = k?.0 ?? ""; i.keyEquivalentModifierMask = k?.1 ?? []
            }
        }
        walk(menu, [])
        if moved { SettingsStore.shared.set("keys", .object(over.mapValues { .string($0) })) }
    }

    /// Before commands had ids, AppKit named Kelp's menu items after their selectors, so overrides were saved as
    /// "File › saveAll". Items that shared a selector (Tab 1–9, panels, Tools) shared one name and don't move.
    private static let legacy = [
        "workbench.openSettings": "openSettings", "workbench.openExtensions": "openExtensions", "workbench.restartService": "restartService",
        "workspace.new": "newWorkspace", "agents.new": "newAgent", "terminal.new": "newTerminal", "workspace.addProject": "addProject",
        "workspace.revealInFinder": "revealInFinder", "editor.save": "saveFile", "editor.saveAll": "saveAll", "editor.closeTab": "closeTab",
        "workspace.close": "closeWorkspace", "files.findInWorkspace": "findInWorkspace", "editor.goToLine": "goToLine",
        "editor.jumpToDefinition": "jumpToDefinition", "editor.sendToAgent": "sendSelection", "editor.copyReference": "copyReference",
        "editor.copyWebLink": "copyWebLink", "workbench.toggleSidebar": "toggleSidebar", "workbench.toggleInspector": "toggleInspector",
        "workbench.toggleFocusMode": "toggleFocusMode", "view.biggerText": "biggerText", "view.smallerText": "smallerText",
        "view.defaultTextSize": "defaultText", "terminal.splitRight": "splitRight", "terminal.splitDown": "splitDown",
        "view.maximizePane": "toggleZoom", "view.equalizePanes": "equalizePanes", "view.nextPane": "nextGroup", "view.previousPane": "prevGroup",
        "editor.nextTab": "nextTab", "editor.previousTab": "prevTab", "workbench.commandPalette": "commandPalette", "files.quickOpen": "quickOpen",
        "agents.history": "showHistory", "scripts.run": "runRun", "scripts.test": "runTest", "scripts.stop": "stop", "scripts.edit": "edit",
        "agents.nextNeedingYou": "nextNeedingAttention", "agents.usage": "showUsage", "workbench.scratch": "showScratch",
        "workspace.switch": "switchWorkspace", "workspace.next": "nextWorkspace", "workspace.previous": "prevWorkspace",
        "workspace.back": "workspaceBack", "workspace.forward": "workspaceForward", "help.guide": "openHelp", "help.extensionGuide": "openExtensionGuide"
    ]

    /// macOS's own app-menu commands (About, Hide, Hide Others, Show All, Quit): System Settings › Keyboard rebinds those.
    private static let systemActions: Set<Selector> = [#selector(NSApplication.orderFrontStandardAboutPanel(_:)), #selector(NSApplication.hide(_:)),
                                                       #selector(NSApplication.hideOtherApplications(_:)), #selector(NSApplication.unhideAllApplications(_:)),
                                                       #selector(NSApplication.terminate(_:))]

    static func entries() -> [Entry] {
        var out: [Entry] = []
        func walk(_ m: NSMenu, _ path: [String]) {
            for i in m.items where !i.isSeparatorItem {
                if let s = i.submenu { if s !== NSApp.servicesMenu { walk(s, path + [i.identifier?.rawValue ?? i.title]) }; continue }
                guard let id = i.identifier?.rawValue, defaults.keys.contains(id), !(i.action.map(systemActions.contains) ?? false) else { continue }
                let key = i.keyEquivalent.isEmpty ? nil : Key(key: i.keyEquivalent, mods: i.keyEquivalentModifierMask.intersection(mask))
                out.append(Entry(id: id, menu: path.map(loc).joined(separator: " › "), title: i.title,
                                 key: key, defaultKey: defaults[id] ?? nil))
            }
        }
        NSApp.mainMenu.map { walk($0, []) }
        return out
    }

    static func matches(_ e: Entry, _ query: String) -> Bool {
        let q = query.lowercased()
        return q.isEmpty || [e.id, e.menu, e.title, e.key.map(display) ?? ""].contains { $0.lowercased().contains(q) }
    }

    /// nil: back to Kelp's default; a key with no key text: no shortcut.
    static func set(_ id: String, _ key: Key?) {
        var o = overrides
        if let key { o[id] = key.key.isEmpty ? "" : spec(key) } else { o[id] = nil }
        SettingsStore.shared.set("keys", o.isEmpty ? nil : .object(o.mapValues { .string($0) }))
    }
    static func resetAll() { SettingsStore.shared.set("keys", nil) }

    /// "shift+cmd+k", the form settings.json and extension manifests use.
    static func spec(_ k: Key) -> String {
        var parts: [String] = []
        if k.mods.contains(.control) { parts.append("ctrl") }
        if k.mods.contains(.option) { parts.append("opt") }
        if k.mods.contains(.shift) { parts.append("shift") }
        if k.mods.contains(.command) { parts.append("cmd") }
        let named: [String: String] = ["\u{F700}": "up", "\u{F701}": "down", "\u{F702}": "left", "\u{F703}": "right", "\r": "return", "\t": "tab",
                                       " ": "space", "\u{1b}": "esc", "\u{8}": "delete", "\u{7f}": "delete", "+": "plus"]
        return (parts + [named[k.key] ?? k.key.lowercased()]).joined(separator: "+")
    }

    /// "⇧⌘K", as menus show it.
    static func display(_ k: Key) -> String {
        var s = ""
        if k.mods.contains(.control) { s += "⌃" }
        if k.mods.contains(.option) { s += "⌥" }
        if k.mods.contains(.shift) { s += "⇧" }
        if k.mods.contains(.command) { s += "⌘" }
        let named: [String: String] = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\r": "↩", "\t": "⇥", " ": String(localized: "Space"),
                                       "\u{1b}": "⎋", "\u{8}": "⌫", "\u{7f}": "⌫"]
        return s + (named[k.key] ?? k.key.uppercased())
    }

    /// What else answers to this combination: another of Kelp's commands, or macOS (which gets it first).
    static func conflict(_ k: Key, keyCode: UInt16?, except id: String) -> String? {
        let norm = Key(key: k.key.lowercased(), mods: k.mods)
        if let other = entries().first(where: { $0.id != id && $0.key.map { Key(key: $0.key.lowercased(), mods: $0.mods) } == norm }) {
            let name = "\(other.menu) › \(other.title)"
            return String(localized: "Also the shortcut for \(name).")
        }
        if let code = keyCode, let name = system[SystemKey(code: code, mods: k.mods.rawValue & mask.rawValue)] {
            return String(localized: "macOS uses this for \(name), so Kelp won't see it (System Settings › Keyboard › Keyboard Shortcuts).")
        }
        return nil
    }

    struct SystemKey: Hashable { var code: UInt16; var mods: UInt }
    /// The enabled shortcuts in System Settings › Keyboard Shortcuts (Spotlight, Mission Control, input sources…).
    static let system: [SystemKey: String] = {
        let names: [Int: String] = [7: String(localized: "moving focus to the menu bar"), 8: String(localized: "moving focus to the Dock"), 9: String(localized: "moving focus to the active window"),
                                    27: String(localized: "moving focus to the next window"), 28: String(localized: "a screenshot"), 29: String(localized: "a screenshot to the clipboard"),
                                    30: String(localized: "a screenshot of an area"), 31: String(localized: "an area screenshot to the clipboard"), 32: "Mission Control",
                                    33: String(localized: "application windows"), 36: String(localized: "Show Desktop"), 52: String(localized: "Dock hiding"), 60: String(localized: "the previous input source"),
                                    61: String(localized: "the next input source"), 64: "Spotlight", 65: String(localized: "Finder search"), 79: String(localized: "moving a space left"),
                                    81: String(localized: "moving a space right"), 98: String(localized: "the Help menu"), 160: "Launchpad", 175: String(localized: "Do Not Disturb"),
                                    184: String(localized: "screenshot options"), 190: String(localized: "Quick Note")]
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") else { return [:] }
        var out: [SystemKey: String] = [:]
        for (k, v) in all {
            guard let d = v as? [String: Any], (d["enabled"] as? Bool) == true || (d["enabled"] as? Int) == 1,
                  let p = (d["value"] as? [String: Any])?["parameters"] as? [Int], p.count == 3, p[1] != 65535 else { continue }
            out[SystemKey(code: UInt16(p[1]), mods: UInt(p[2]) & mask.rawValue)] = names[Int(k) ?? -1] ?? String(localized: "a system shortcut")
        }
        return out
    }()
}

/// The Keyboard page: every command, its shortcut, click to record a new one. Settings' own search filters it
/// (`query`), so the page has no second search field.
struct KeyboardSettings: View {
    var query = ""
    @State private var entries: [KeyBindings.Entry] = []
    @State private var recording: String?
    @State private var warning: [String: String] = [:]
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Click a shortcut, then press the new keys. ⌫ removes it, Esc keeps it.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { KeyBindings.resetAll(); later() }.disabled(KeyBindings.overrides.isEmpty)
            }
            ForEach(groups, id: \.0) { menu, items in
                Text(menu).font(.headline).padding(.top, 6)
                ForEach(items) { e in row(e) }
            }
        }
        .onAppear { entries = KeyBindings.entries() }
        .onDisappear { stop() }
    }

    private var groups: [(String, [KeyBindings.Entry])] {
        let shown = entries.filter { KeyBindings.matches($0, query) }
        var order: [String] = [], by: [String: [KeyBindings.Entry]] = [:]
        for e in shown { if by[e.menu] == nil { order.append(e.menu) }; by[e.menu, default: []].append(e) }
        return order.map { ($0, by[$0] ?? []) }
    }

    @ViewBuilder private func row(_ e: KeyBindings.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(e.title)
                Spacer()
                if e.key != e.defaultKey {
                    Button("Default") { KeyBindings.set(e.id, nil); warning[e.id] = nil; later() }.buttonStyle(.link).font(.caption)
                        .help(e.defaultKey.map { String(localized: "Kelp's default: \(KeyBindings.display($0))") } ?? String(localized: "Kelp's default: none"))
                }
                Button { record(e.id) } label: {
                    Text(recording == e.id ? String(localized: "Type shortcut…") : e.key.map(KeyBindings.display) ?? "—").frame(minWidth: 96)
                }
                .foregroundStyle(recording == e.id ? Color.accentColor : e.key == nil ? .secondary : .primary)
            }
            if let w = warning[e.id] { Text(w).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func record(_ id: String) {
        stop()
        recording = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            let mods = ev.modifierFlags.intersection([.command, .shift, .option, .control])
            let chars = ev.charactersIgnoringModifiers ?? ""
            switch ev.keyCode {
            case 53 where mods.isEmpty: stop()   // Esc: keep it
            case 51 where mods.isEmpty: KeyBindings.set(id, .init(key: "", mods: [])); warning[id] = nil; stop(); later()   // ⌫: none
            default:
                let fKey = (0xF704...0xF70F).contains(chars.unicodeScalars.first?.value ?? 0)
                guard !mods.subtracting(.shift).isEmpty || fKey else { NSSound.beep(); return nil }   // a plain letter would type
                let key = KeyBindings.Key(key: mods.contains(.shift) && chars.count == 1 ? chars.uppercased() : chars, mods: mods)
                warning[id] = KeyBindings.conflict(key, keyCode: ev.keyCode, except: id)
                KeyBindings.set(id, key); stop(); later()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = nil
    }

    /// The menu is rebuilt from the setting a moment later; read it back then.
    private func later() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { entries = KeyBindings.entries() } }
}
