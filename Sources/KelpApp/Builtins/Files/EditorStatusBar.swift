import AppKit
import UniformTypeIdentifiers
import WorkbenchKit

/// Under a code file, like Xcode's and BBEdit's: what kind of file it is, where the cursor is, the encoding and the
/// indentation the file uses.
@MainActor
final class EditorStatusBar: NSView {
    private let place = NSTextField(labelWithString: "")

    init(url: URL, text: String) {
        super.init(frame: .zero)
        let kind = NSTextField(labelWithString: UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? url.pathExtension.uppercased())
        let indent: String = switch Indentation.detect(text) {
        case .tabs?: String(localized: "Tabs")
        case .spaces(let n)?: String(localized: "Spaces: \(n)")
        case nil: ""
        }
        let format = NSTextField(labelWithString: ["UTF-8", indent].filter { !$0.isEmpty }.joined(separator: "  ·  "))
        for l in [kind, place, format] { l.font = .ui(11); l.textColor = .secondaryLabelColor; l.lineBreakMode = .byTruncatingTail }
        kind.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [kind, place, NSView(), format]); row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let line = NSBox(); line.boxType = .separator
        for v in [row, line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            line.topAnchor.constraint(equalTo: topAnchor), line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(cursor: (line: Int, column: Int)?) {
        place.stringValue = cursor.map { String(localized: "Line \($0.line), Column \($0.column)") } ?? ""
    }

    /// The editor over the bar, in one view.
    static func wrap(_ editor: NSView, bar: EditorStatusBar) -> NSView {
        let v = NSView()
        for x in [editor, bar] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: v.topAnchor), editor.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: v.trailingAnchor), editor.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor), bar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        ])
        return v
    }
}
