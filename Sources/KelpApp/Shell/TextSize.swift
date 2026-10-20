import AppKit

/// Settings › Appearance › Sidebar and inspector text: larger text there for people who want it (the terminal and the
/// editor have their own font sizes). The sidebar redraws and the inspector's panels are rebuilt when it changes.
enum TextSize {
    static var scale: CGFloat = 1

    static func apply(_ name: String?) {
        let s: CGFloat = ["large": 1.15, "larger": 1.3][name ?? ""] ?? 1
        guard s != scale else { return }
        scale = s
        NotificationCenter.default.post(name: .kelpTextSize, object: nil)
    }

    /// A row or spacing measured for normal text, at this size.
    static func of(_ points: CGFloat) -> CGFloat { (points * scale).rounded() }
}

extension NSFont {
    /// The system font at `size` for normal text, scaled by the text-size setting (sidebar and inspector).
    static func ui(_ size: CGFloat, weight: Weight = .regular) -> NSFont { .systemFont(ofSize: TextSize.of(size), weight: weight) }
    static func uiDigits(_ size: CGFloat, weight: Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: TextSize.of(size), weight: weight) }
}

extension Notification.Name { static let kelpTextSize = Notification.Name("kelp.textSize") }
