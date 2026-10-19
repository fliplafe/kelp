import AppKit

/// Text as it should leave a terminal: what TUIs paint around it (box borders, an agent's indented gutter, padding to the
/// right edge) isn't part of it.
public enum TerminalCopy {
    static let borders: Set<Character> = ["│", "┃", "║", "▏", "▕"]

    public static func clean(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n").map { trimRight($0) }
        // A frame's sides: "│ text │" → "text", when every non-empty line has one.
        let full = lines.filter { !$0.isEmpty }
        if !full.isEmpty, full.allSatisfy({ borders.contains($0.trimmingCharacters(in: .whitespaces).first ?? " ") }) {
            lines = lines.map { l in
                var t = Substring(l.drop { $0 == " " })
                if let f = t.first, borders.contains(f) { t = t.dropFirst() }
                if let e = t.last, borders.contains(e) { t = t.dropLast() }
                return trimRight(String(t))
            }
        }
        // The indent all lines share (Claude Code and Codex draw their text in a gutter).
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }
        if let m = indents.min(), m > 0 { lines = lines.map { String($0.dropFirst(min(m, $0.prefix { $0 == " " }.count))) } }
        return lines.joined(separator: "\n")
    }

    static func trimRight(_ s: String) -> String {
        var t = Substring(s)
        while let c = t.last, c == " " || c == "\t" || c == "\u{00A0}" { t = t.dropLast() }
        return String(t)
    }

    /// The word around column `col` of a screen row: up to blanks, quotes and brackets, without sentence punctuation
    /// at its end. `start` is its first column.
    public static func word(in line: String, at col: Int) -> (text: String, start: Int)? {
        let chars = Array(line)
        guard chars.indices.contains(col) else { return nil }
        let stops: Set<Character> = [" ", "\t", "\"", "'", "`", "(", ")", "[", "]", "{", "}", "<", ">", "|", "│", ","]
        guard !stops.contains(chars[col]) else { return nil }
        var a = col, b = col
        while a > 0, !stops.contains(chars[a - 1]) { a -= 1 }
        while b + 1 < chars.count, !stops.contains(chars[b + 1]) { b += 1 }
        var w = String(chars[a...b])
        while let last = w.last, ".:;!?".contains(last) { w.removeLast() }
        return w.isEmpty ? nil : (w, a)
    }
}

/// Where the scrollback is, along the right edge, while it moves (like an overlay scroller); it lets clicks through.
@MainActor
final class ScrollIndicator: NSView {
    private let knob = CALayer()
    private var hide: DispatchWorkItem?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; alphaValue = 0
        knob.cornerRadius = 3; layer?.addSublayer(knob)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    /// Rows between the view and the bottom: it changes when you scroll, not when output streams in at the bottom.
    private var fromBottom: Double?

    func show(total: Double, offset: Double, length: Double) {
        let now = total - length - offset
        defer { fromBottom = now }
        guard total > length, length > 0 else { alphaValue = 0; return }
        guard let was = fromBottom, was != now else { return }
        let h = max(24, bounds.height * length / total)
        let y = (bounds.height - h) * (1 - offset / max(1, total - length))   // offset 0 = the top of the scrollback
        effectiveAppearance.performAsCurrentDrawingAppearance { knob.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        knob.frame = NSRect(x: 1, y: y, width: 5, height: h)
        CATransaction.commit()
        alphaValue = 1
        hide?.cancel()
        let w = DispatchWorkItem { [weak self] in NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self?.animator().alphaValue = 0 } }
        hide = w; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
}

/// "120 × 40" in the middle of a terminal while it's resized, then gone.
@MainActor
final class SizeBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hide: DispatchWorkItem?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 8; isHidden = true
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium); label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    func show(_ text: String, in b: NSRect) {
        label.stringValue = text
        let w = label.intrinsicContentSize.width + 28
        frame = NSRect(x: b.midX - w / 2, y: b.midY - 18, width: w, height: 36)
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor }
        isHidden = false
        hide?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.isHidden = true }
        hide = item; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }
}
