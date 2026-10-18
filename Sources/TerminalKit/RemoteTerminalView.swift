import AppKit
import SwiftTerm

/// The app talks to terminals only through this type, not to SwiftTerm/libghostty directly.
/// The emulator renders bytes the daemon streams; keystrokes go back out via `onInput`.
@MainActor
public final class RemoteTerminalView: NSView, @preconcurrency TerminalViewDelegate {
    private let term = TerminalView(frame: .zero)
    public var onInput: ((Data) -> Void)?
    public var onResize: ((Int, Int) -> Void)?
    public var onTitle: ((String) -> Void)?
    public var onFocus: (() -> Void)?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        term.terminalDelegate = self
        term.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        term.translatesAutoresizingMaskIntoConstraints = false
        addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: leadingAnchor), term.trailingAnchor.constraint(equalTo: trailingAnchor),
            term.topAnchor.constraint(equalTo: topAnchor), term.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    public required init?(coder: NSCoder) { fatalError() }

    public func feed(_ data: Data) { term.feed(byteArray: ArraySlice([UInt8](data))) }
    public private(set) var cols = 120
    public private(set) var rows = 32
    /// Visible buffer as plain text (tests, "send selection", snapshots).
    public var text: String { String(decoding: term.getBufferAsData(), as: UTF8.self) }
    public var selection: String? { term.getSelection() }
    public func focus() { window?.makeFirstResponder(term) }
    public func setFont(name: String?, size: CGFloat) {
        term.font = name.flatMap { NSFont(name: $0, size: size) } ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    public func apply(theme: TerminalTheme) {
        term.nativeBackgroundColor = theme.background; term.nativeForegroundColor = theme.foreground
    }

    public override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }

    // MARK: TerminalViewDelegate
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { cols = newCols; rows = newRows; onResize?(newCols, newRows) }
    public func setTerminalTitle(source: TerminalView, title: String) { onTitle?(title) }
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func send(source: TerminalView, data: ArraySlice<UInt8>) { onInput?(Data(data)) }
    public func scrolled(source: TerminalView, position: Double) {}
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let u = URL(string: link) { NSWorkspace.shared.open(u) }
    }
    public func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: content, as: UTF8.self), forType: .string)
    }
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

public struct TerminalTheme: Sendable {
    public var background: NSColor, foreground: NSColor
    public init(background: NSColor, foreground: NSColor) { self.background = background; self.foreground = foreground }
}
