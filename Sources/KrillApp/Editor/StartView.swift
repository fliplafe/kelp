import AppKit
import Core

/// An empty workspace: what can be opened here, one click each (like Xcode's welcome window) — the installed agents,
/// a terminal, and whatever extensions add (the browser…).
@MainActor
final class StartView: NSView {
    var onAgent: ((String) -> Void)?
    var onOpen: ((String) -> Void)?

    init(worktree w: Worktree) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: w.displayName)
        title.font = .systemFont(ofSize: 22, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        let folder = NSTextField(labelWithString: (w.path as NSString).abbreviatingWithTildeInPath)
        folder.font = .systemFont(ofSize: 12); folder.textColor = .secondaryLabelColor; folder.lineBreakMode = .byTruncatingMiddle

        let agents = AgentCatalog.installed(AgentCatalog.all)
        var rows: [NSView] = agents.map { a in
            StartRow(symbol: AgentCatalog.symbol(a.id), title: a.name,
                     shortcut: a.id == AgentCatalog.defaultAgent ? "⌥⌘T" : nil) { [weak self] in self?.onAgent?(a.id) }
        }
        if agents.isEmpty {
            let none = NSTextField(wrappingLabelWithString: "No agent found. Install Claude Code, Codex or another agent CLI, then come back.")
            none.textColor = .secondaryLabelColor
            rows.append(none)
        }
        rows.append(StartRow(symbol: "terminal", title: "Terminal", shortcut: "⌘T") { [weak self] in self?.onOpen?("terminal:") })
        // Changes live in Source Control; the rest of what extensions open is offered here.
        for e in ExtensionRegistry.shared.all.editors where e.id != "git.review" {
            let key = ExtensionRegistry.shared.command(e.id)?.key.flatMap(StartRow.symbols)
            rows.append(StartRow(symbol: e.icon, title: e.title, shortcut: key) { e.open(IDEContext.current) })
        }

        let list = NSStackView(views: rows); list.orientation = .vertical; list.alignment = .leading; list.spacing = 2
        let stack = NSStackView(views: [title, folder, list]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.setCustomSpacing(20, after: folder)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: 360); width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            width, stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor), folder.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        rows.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    func focus() {}
}

/// One action: symbol, title, its shortcut on the right; highlights on hover.
@MainActor
private final class StartRow: NSView {
    private let action: () -> Void
    private var hover = false { didSet { updateLayer() } }

    init(symbol: String, title: String, shortcut: String?, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 7
        let icon = NSImageView(image: .symbol(symbol, title)); icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13)
        let key = NSTextField(labelWithString: shortcut ?? ""); key.textColor = .tertiaryLabelColor; key.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [icon, label, NSView(), key]); row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34), icon.widthAnchor.constraint(equalToConstant: 22),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hover ? NSColor.quaternaryLabelColor.withAlphaComponent(0.35).cgColor : NSColor.clear.cgColor
        }
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { action() } }
    override func accessibilityPerformPress() -> Bool { action(); return true }

    /// "shift+cmd+b" → "⇧⌘B".
    static func symbols(_ key: String) -> String? {
        guard let (k, mods) = AppDelegate.parseKey(key) else { return nil }
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s + k.uppercased()
    }
}

extension Worktree {
    /// The name people see: their own, or the branch.
    var displayName: String { note.isEmpty ? branch : note }
}
