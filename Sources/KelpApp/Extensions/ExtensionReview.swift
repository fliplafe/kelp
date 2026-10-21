import AppKit
import Core

/// The look before an extension from GitHub goes in: what it can run on this Mac, in a sheet.
@MainActor
enum ExtensionReview {
    static func approve(_ folder: URL) async -> Bool {
        let manifest = (try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent("extension.json")))) ?? .null
        let (commands, pages) = IDE.commandsIn(manifest)
        let lines = commands + pages.map { String(localized: "\($0) — a web page, which can run any command") }
        let a = NSAlert()
        a.messageText = String(localized: "Install “\(manifest["name"]?.string ?? folder.lastPathComponent)”?")
        a.informativeText = lines.isEmpty ? String(localized: "It runs no commands.") : String(localized: "It can run these commands on this Mac:")
        a.addButton(withTitle: String(localized: "Install"))
        a.addButton(withTitle: String(localized: "Cancel"))
        if !lines.isEmpty { a.accessoryView = list(lines) }
        return await runSheet(a) == .alertFirstButtonReturn
    }

    private static func list(_ lines: [String]) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: min(220, CGFloat(lines.count) * 17 + 10))
        scroll.borderType = .bezelBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.string = lines.joined(separator: "\n")
            tv.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            tv.isEditable = false
            tv.textContainerInset = NSSize(width: 4, height: 4)
        }
        return scroll
    }
}
