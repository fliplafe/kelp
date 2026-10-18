import AppKit

/// A short message over the bottom of the window — errors and confirmations that shouldn't block anything.
@MainActor
enum Banner {
    enum Style { case info, error }
    private static var current: NSView?

    static func show(_ text: String, style: Style = .info) {
        guard let content = (NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible })?.contentView else { return }
        current?.removeFromSuperview()
        let fx = NSVisualEffectView(); fx.material = .hudWindow; fx.blendingMode = .withinWindow; fx.state = .active
        fx.wantsLayer = true; fx.layer?.cornerRadius = 10
        let icon = NSImageView(image: .symbol(style == .error ? "exclamationmark.triangle.fill" : "info.circle.fill"))
        icon.contentTintColor = style == .error ? .systemOrange : .secondaryLabelColor
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 12); label.isSelectable = true
        label.preferredMaxLayoutWidth = 460
        let row = NSStackView(views: [icon, label]); row.spacing = 8; row.alignment = .top
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 14)
        for v in [row] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; fx.addSubview(v) }
        fx.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(fx)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: fx.topAnchor), row.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: fx.leadingAnchor), row.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            fx.centerXAnchor.constraint(equalTo: content.centerXAnchor), fx.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            fx.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
        ])
        current = fx
        fx.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; fx.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + (style == .error ? 6 : 3)) { [weak fx] in
            guard let fx else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; fx.animator().alphaValue = 0 }) { MainActor.assumeIsolated { fx.removeFromSuperview() } }
        }
    }
}
