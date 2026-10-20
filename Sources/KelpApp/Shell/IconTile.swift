import AppKit

/// The small rounded tiles agents and projects show as (sidebar, tabs, menus), so every row's icon has the same size
/// and shape: an app's icon filling its tile without the margin macOS draws around it, or the name's initial on a colour.
@MainActor
enum IconTile {
    nonisolated static let side: CGFloat = 32

    /// A Mac app's icon cropped to its body: on the Big Sur grid the body is 824 of the 1024-point canvas.
    static func app(_ icon: NSImage) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).addClip()
            let grow = r.width * (1024.0 / 824.0 - 1) / 2
            icon.draw(in: r.insetBy(dx: -grow, dy: -grow))
            return true
        }
    }

    /// The name's initial in white on a colour: `color`, or one picked from the name (the same name, the same colour).
    static func letter(_ name: String, color: NSColor? = nil, size: CGFloat = side) -> NSImage {
        let initial = name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
        let fill = color ?? palette[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            fill.setFill(); NSBezierPath(roundedRect: r, xRadius: r.width * 7 / 32, yRadius: r.height * 7 / 32).fill()
            let s = NSAttributedString(string: initial, attributes: [.font: NSFont.systemFont(ofSize: r.height * 0.62, weight: .bold),
                                                                     .foregroundColor: NSColor.white])
            let b = s.size()
            s.draw(at: NSPoint(x: r.midX - b.width / 2, y: r.midY - b.height / 2))
            return true
        }
        img.accessibilityDescription = name
        return img
    }

    private static let palette: [NSColor] = [.systemPurple, .systemBlue, .systemTeal, .systemGreen, .systemOrange, .systemPink, .systemIndigo, .systemBrown]
}
