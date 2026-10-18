import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView
import SwiftUI

/// The app talks to the editor only through this type (tree-sitter highlighting, find/replace,
/// multi-cursor and folding come from CodeEditSourceEditor).
@MainActor
public final class CodeEditor: NSObject {
    public static let readOnlyLimit = 5 * 1024 * 1024
    public let controller: TextViewController
    public var onChange: ((String) -> Void)?
    public var onSelection: (() -> Void)?
    private var suppress = false

    public init(text: String, url: URL, editable: Bool = true, fontSize: CGFloat = 13) {
        let lang = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(text.prefix(200)))
        let cfg = SourceEditorConfiguration(
            appearance: .init(theme: Self.theme, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular), wrapLines: false),
            behavior: .init(isEditable: editable)
        )
        let relay = Relay()
        controller = TextViewController(string: text, language: lang, configuration: cfg, cursorPositions: [CursorPosition(line: 1, column: 1)], coordinators: [relay])
        super.init()
        relay.owner = self
    }

    public var view: NSView { controller.view }
    public var text: String { controller.text }

    /// Replace contents (e.g. the file changed on disk) without echoing a change event.
    public func setText(_ s: String) {
        guard s != controller.text else { return }
        let cursors = controller.cursorPositions
        suppress = true; controller.setText(s); suppress = false
        controller.setCursorPositions(cursors.map { CursorPosition(line: $0.start.line, column: $0.start.column) })
    }

    public var selectedText: String? {
        guard let tv = controller.textView else { return nil }
        let parts = tv.selectionManager.textSelections.map(\.range).filter { $0.length > 0 }.compactMap { tv.textStorage.attributedSubstring(from: $0).string as String? }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
    public var selectedLines: ClosedRange<Int>? {
        guard let c = controller.cursorPositions.first else { return nil }
        return c.start.line...(c.end?.line ?? c.start.line)
    }

    /// 1-based line/column of the primary cursor.
    public var cursor: (line: Int, column: Int)? { controller.cursorPositions.first.map { ($0.start.line, $0.start.column) } }

    /// Completion items come from the app (LSP); the editor shows its native suggestion window.
    public var completionProvider: ((Int, Int) async -> [Completion])? {
        didSet { completer.owner = self; controller.completionDelegate = completionProvider == nil ? nil : completer }
    }
    private let completer = Completer()

    public struct Completion: CodeSuggestionEntry {
        public var label: String
        public var detail: String?
        public var insert: String
        public var documentation: String? { nil }
        public var pathComponents: [String]? { nil }
        public var targetPosition: CursorPosition? { nil }
        public var sourcePreview: String? { nil }
        public var image: Image { Image(systemName: "chevron.left.forwardslash.chevron.right") }
        public var imageColor: Color { .secondary }
        public var deprecated: Bool { false }
        public init(label: String, detail: String?, insert: String) { self.label = label; self.detail = detail; self.insert = insert }
    }

    /// Replace the identifier left of the cursor with `text`.
    fileprivate func applyCompletion(_ text: String) {
        guard let tv = controller.textView, let c = controller.cursorPositions.first else { return }
        let ns = tv.string as NSString
        var start = c.range.location
        while start > 0, let u = UnicodeScalar(ns.character(at: start - 1)), CharacterSet.alphanumerics.union(.init(charactersIn: "_$")).contains(u) { start -= 1 }
        tv.replaceCharacters(in: NSRange(location: start, length: c.range.location - start), with: text)
    }

    public func goTo(line: Int) { controller.setCursorPositions([CursorPosition(line: max(1, line), column: 1)], scrollToVisible: true) }
    public func focus() { controller.view.window?.makeFirstResponder(controller.textView) }

    fileprivate func changed() { if !suppress { onChange?(controller.text) } }

    /// Xcode-like default themes; colors must be concrete RGB (the editor reads brightness components).
    static var theme: EditorTheme {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        func c(_ hex: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1) }
        func a(_ hex: UInt32, bold: Bool = false) -> EditorTheme.Attribute { .init(color: c(hex), bold: bold) }
        if dark {
            return EditorTheme(text: a(0xDFDFE0), insertionPoint: c(0xFFFFFF), invisibles: a(0x53606E), background: c(0x1F1F24),
                               lineHighlight: c(0x23252B), selection: c(0x515B70), keywords: a(0xFF7AB2, bold: true), commands: a(0x67B7A4),
                               types: a(0x5DD8FF), attributes: a(0xCC9768), variables: a(0x41A1C0), values: a(0xA167E6),
                               numbers: a(0xD9C97C), strings: a(0xFF8170), characters: a(0xD9C97C), comments: a(0x7F8C98))
        }
        return EditorTheme(text: a(0x000000), insertionPoint: c(0x000000), invisibles: a(0xD6D6D6), background: c(0xFFFFFF),
                           lineHighlight: c(0xECF5FF), selection: c(0xB2D7FF), keywords: a(0x9B2393, bold: true), commands: a(0x326D74),
                           types: a(0x0B4F79), attributes: a(0x815F03), variables: a(0x0F68A0), values: a(0x6C36A9),
                           numbers: a(0x1C00CF), strings: a(0xC41A16), characters: a(0x1C00CF), comments: a(0x5D6C79))
    }
}

/// Receives CodeEditSourceEditor callbacks and forwards them to the owning editor.
private final class Relay: TextViewCoordinator {
    weak var owner: CodeEditor?
    func prepareCoordinator(controller: TextViewController) {}
    func textViewDidChangeText(controller: TextViewController) { MainActor.assumeIsolated { owner?.changed() } }
    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) { MainActor.assumeIsolated { owner?.onSelection?() } }
    func destroy() {}
}

private final class Completer: CodeSuggestionDelegate {
    weak var owner: CodeEditor?
    private var last: [CodeEditor.Completion] = []
    func completionTriggerCharacters() -> Set<String> { [".", ":"] }
    func completionSuggestionsRequested(textView: TextViewController, cursorPosition: CursorPosition) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let o = await MainActor.run(body: { owner }), let p = await MainActor.run(body: { o.completionProvider }) else { return nil }
        let items = await p(cursorPosition.start.line, cursorPosition.start.column)
        last = items
        return items.isEmpty ? nil : (cursorPosition, items)
    }
    func completionOnCursorMove(textView: TextViewController, cursorPosition: CursorPosition) -> [CodeSuggestionEntry]? { nil }
    func completionWindowApplyCompletion(item: CodeSuggestionEntry, textView: TextViewController, cursorPosition: CursorPosition?) {
        guard let c = item as? CodeEditor.Completion else { return }
        MainActor.assumeIsolated { owner?.applyCompletion(c.insert) }
    }
}
