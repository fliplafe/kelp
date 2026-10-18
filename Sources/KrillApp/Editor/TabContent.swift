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
    var toolTip: String? { get }
    /// Called when title / icon / status change.
    var onChange: (() -> Void)? { get set }
    func focus()
    /// Return false to keep the tab (e.g. the user cancelled).
    func close() -> Bool
}

extension TabContent {
    var status: AgentStatus? { nil }
    var toolTip: String? { nil }
    func close() -> Bool { true }
}

/// URI helpers: "session:ID", "file:///abs#L12", "diff:path", "https://…", "chat:ID", "ext:id/view".
enum TabURI {
    static func scheme(_ uri: String) -> String {
        guard let i = uri.firstIndex(of: ":") else { return "file" }
        return uri[..<i].lowercased()
    }
    static func body(_ uri: String) -> String {
        guard let i = uri.firstIndex(of: ":") else { return uri }
        return String(uri[uri.index(after: i)...])
    }
    static func session(_ id: String) -> String { "session:\(id)" }
    static func file(_ path: String, line: Int? = nil) -> String {
        "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + (line.map { "#L\($0)" } ?? "")
    }
    /// Absolute path and line of a file URI (also accepts a bare path).
    static func filePath(_ uri: String) -> (path: String, line: Int?) {
        var s = uri.hasPrefix("file://") ? String(uri.dropFirst(7)) : uri
        var line: Int?
        if let h = s.range(of: "#L") { line = Int(s[h.upperBound...]); s = String(s[..<h.lowerBound]) }
        return (s.removingPercentEncoding ?? s, line)
    }
    /// What the user typed or an agent sent: path, path:line, URL.
    static func normalize(_ s: String, cwd: String?) -> String {
        if s.contains("://") || ["session:", "chat:", "ext:", "diff:"].contains(where: s.hasPrefix) { return s }
        if s.hasPrefix("localhost") || s.hasPrefix("127.0.0.1") { return "http://" + s }
        var p = s, line: Int?
        if let r = s.range(of: #":(\d+)$"#, options: .regularExpression) { line = Int(s[r].dropFirst()); p = String(s[..<r.lowerBound]) }
        if !p.hasPrefix("/"), let cwd { p = (cwd as NSString).appendingPathComponent(p) }
        return file(p, line: line)
    }
}

/// SF Symbol image helper used by tabs and menus.
extension NSImage {
    static func symbol(_ name: String, _ label: String? = nil) -> NSImage { NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage() }
}
