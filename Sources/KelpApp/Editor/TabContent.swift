import AppKit
import Core
import WorkbenchKit

/// Anything shown as a tab in the editor area. Made by a `TabProvider` from a URI.
@MainActor
protocol TabContent: AnyObject {
    var view: NSView { get }
    var uri: String { get }
    var title: String { get }
    var icon: NSImage? { get }
    /// Agent tabs report their status; it shows on the tab.
    var status: AgentStatus? { get }
    /// Finished and not looked at yet (the filled ✓).
    var unread: Bool { get }
    var toolTip: String? { get }
    /// How full an agent's conversation is (0…1); the tab shows a ring from 75 %.
    var meter: Double? { get }
    /// How far what runs in it got (0…1), when it says: its status mark fills.
    var progress: Double? { get }
    /// Unsaved changes: the tab shows a dot, closing it asks first.
    var isEdited: Bool { get }
    /// Called when title / icon / status / edited state change.
    var onChange: (() -> Void)? { get set }
    func focus()
    /// Return false to keep the tab (e.g. the user cancelled). Questions are sheets, awaited.
    func close() async -> Bool

    // What the shell asks of a tab without knowing its kind (built-ins answer; the defaults say "not this one").
    /// The colored ring around its pane: an agent asking (orange), failed (red), finished unseen (accent).
    var attention: NSColor? { get }
    /// A terminal: it fades a little in an unfocused split, like Ghostty's.
    var isTerminal: Bool { get }
    /// Columns × rows of the terminal on screen, which sizes the next one before it's shown.
    var terminalGrid: (cols: Int, rows: Int)? { get }
    /// The file it shows (Reveal in Finder).
    var fileURL: URL? { get }
    /// Its language, when ⌘R / ⌘U can run it without a project command.
    var language: LanguageSpec? { get }
    /// The command that runs it ("run") or its test at the cursor ("test"); nil when there is none.
    func command(_ name: String) async -> String?
    /// Shows that line (a link to a file that's already open at another line).
    func goTo(line: Int)
}

/// A tab holding work that can be unsaved: ⌘S, Save All and quitting save it.
@MainActor
protocol SavableTab: TabContent {
    /// False when nothing was written (the user cancelled, or it failed and said why).
    @discardableResult func save() async -> Bool
    /// The user chose Don't Save for a tab that's going away: it isn't edited any more, and nothing writes it later.
    func discard()
    /// A save still on its way (a remote file's, to its host): what closing or quitting waits for.
    var pendingSave: Task<Void, Never>? { get }
}

extension SavableTab {
    var pendingSave: Task<Void, Never>? { nil }
}

extension TabContent {
    var status: AgentStatus? { nil }
    var unread: Bool { false }
    var toolTip: String? { nil }
    var meter: Double? { nil }
    var progress: Double? { nil }
    var isEdited: Bool { false }
    func close() async -> Bool { true }
    var attention: NSColor? { nil }
    var isTerminal: Bool { false }
    var terminalGrid: (cols: Int, rows: Int)? { nil }
    var fileURL: URL? { nil }
    var language: LanguageSpec? { nil }
    func command(_ name: String) async -> String? { nil }
    func goTo(line: Int) {}
}

/// SF Symbol image helper used by tabs and menus; a few names get Kelp's own drawing instead (Glyph).
extension NSImage {
    static func symbol(_ name: String, _ label: String? = nil) -> NSImage {
        if let g = Glyph.image(name) { g.accessibilityDescription = label; return g }
        return NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
    }
}
