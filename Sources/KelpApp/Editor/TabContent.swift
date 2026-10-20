import AppKit
import Core

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
    /// Unsaved changes: the tab shows a dot, closing it asks first.
    var isEdited: Bool { get }
    /// Called when title / icon / status / edited state change.
    var onChange: (() -> Void)? { get set }
    func focus()
    /// Return false to keep the tab (e.g. the user cancelled).
    func close() -> Bool
}

/// A tab holding work that can be unsaved: ⌘S, Save All and quitting save it.
@MainActor
protocol SavableTab: TabContent {
    /// False when nothing was written (the user cancelled, or it failed and said why).
    @discardableResult func save() -> Bool
}

extension TabContent {
    var status: AgentStatus? { nil }
    var unread: Bool { false }
    var toolTip: String? { nil }
    var meter: Double? { nil }
    var isEdited: Bool { false }
    func close() -> Bool { true }
}

/// SF Symbol image helper used by tabs and menus; a few names get Kelp's own drawing instead (Glyph).
extension NSImage {
    static func symbol(_ name: String, _ label: String? = nil) -> NSImage {
        if let g = Glyph.image(name) { g.accessibilityDescription = label; return g }
        return NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
    }
}
