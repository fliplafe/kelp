import AppKit
import EditorKit
import WorkbenchKit

/// "untitled:<n>": a new file with no name yet, like VS Code's Untitled-1. Plain text until it's saved: the first ⌘S
/// asks where and under what name (the extension makes it code; none makes it .txt), then the tab is that file's.
@MainActor
final class UntitledTab: SavableTab {
    let uri: String
    private let editor = CodeEditor(text: "", url: URL(fileURLWithPath: "/Untitled.txt"))
    private var wasEdited = false
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?
    var view: NSView { editor.view }
    let title: String
    var icon: NSImage? { .symbol("doc") }
    var isEdited: Bool { !editor.text.isEmpty }

    init(uri: String) {
        self.uri = uri
        title = String(localized: "Untitled-\(TabURI.body(uri))")
        editor.view.clipsToBounds = true
        editor.onChange = { [weak self] _ in
            guard let self, isEdited != wasEdited else { return }
            wasEdited = isEdited; onChange?()
        }
        observer = NotificationCenter.default.addObserver(forName: .kelpAppearance, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.editor.refreshAppearance() }
        }
    }
    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// The next free number in this workspace: Untitled-1, Untitled-2…
    static func next() -> String {
        let open = Set(Workbench.editor?.layout.allTabs.map(\.uri) ?? [])
        return (1...).lazy.map { "untitled:\($0)" }.first { !open.contains($0) } ?? "untitled:1"
    }

    func focus() { editor.focus() }

    func close() -> Bool {
        guard isEdited else { return true }
        let a = NSAlert(); a.messageText = String(localized: "Do you want to save “\(title)”?")
        a.informativeText = String(localized: "It hasn't been saved yet, so its text will be lost if you don't save it.")
        a.addButton(withTitle: String(localized: "Save…")); a.addButton(withTitle: String(localized: "Cancel")); a.addButton(withTitle: String(localized: "Don't Save"))
        switch runAsSheet(a) {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    /// Asks for a name in the workspace's folder, writes the file and puts it in this tab's place.
    @discardableResult
    func save() -> Bool {
        let p = NSSavePanel()
        p.nameFieldStringValue = Self.suggestedName(editor.text) ?? title
        p.directoryURL = AppModel.shared.worktree(Workbench.shared.workspaceId).map { URL(fileURLWithPath: $0.path) }
        p.canCreateDirectories = true; p.isExtensionHidden = false
        p.message = String(localized: "Name it with an extension for code (main.py, App.swift); without one it's a .txt file.")
        guard runAsSheet(p) == .OK, var url = p.url else { return false }
        if url.pathExtension.isEmpty { url.appendPathExtension("txt") }
        do { try editor.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { Banner.show(String(localized: "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")); return false }
        Workbench.editor?.replace(uri, with: TabURI.file(url.path))
        return true
    }

    /// The first line, as VS Code proposes it: "def main():" → "def main()".
    static func suggestedName(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let name = line.components(separatedBy: CharacterSet(charactersIn: "/:\\\"*?<>|")).joined().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : String(name.prefix(40)).trimmingCharacters(in: .whitespaces)
    }
}
