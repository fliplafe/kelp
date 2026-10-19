import AppKit
import GitKit
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
        let folder = NSTextField(labelWithString: RemoteHost.of(w.path).map { "\($0.host):\($0.path)" } ?? (w.path as NSString).abbreviatingWithTildeInPath)
        folder.font = .systemFont(ofSize: 12); folder.textColor = .secondaryLabelColor; folder.lineBreakMode = .byTruncatingMiddle

        // The default agent first, then the others in two columns (people often have a dozen).
        let def = AgentCatalog.defaultAgent
        let agents = AgentCatalog.installed(AgentCatalog.all).sorted { ($0.id == def ? 0 : 1, $0.name) < ($1.id == def ? 0 : 1, $1.name) }
        let tiles = agents.map { a in
            StartRow(image: AgentCatalog.icon(a.id, size: 18), title: a.name, shortcut: a.id == def ? "⌥⌘T" : nil) { [weak self] in self?.onAgent?(a.id) }
        }
        var rows: [NSView] = []
        if agents.isEmpty {
            let none = NSTextField(wrappingLabelWithString: String(localized: "No agent found. Install Claude Code or another agent CLI — Krill picks it up when you come back."))
            none.textColor = .secondaryLabelColor
            rows.append(none)
        } else {
            let grid = NSGridView(numberOfColumns: 2, rows: 0); grid.columnSpacing = 8; grid.rowSpacing = 2
            for i in stride(from: 0, to: tiles.count, by: 2) {
                grid.addRow(with: [tiles[i], i + 1 < tiles.count ? tiles[i + 1] : NSGridCell.emptyContentView])
            }
            rows.append(grid)
            let sep = NSBox(); sep.boxType = .separator; rows.append(sep)
        }
        rows.append(StartRow(image: .symbol("terminal"), title: String(localized: "Terminal"), shortcut: "⌘T") { [weak self] in self?.onOpen?("terminal:") })
        // Changes live in Source Control; the rest of what extensions open is offered here.
        for e in ExtensionRegistry.shared.all.editors where e.id != "git.review" {
            let key = ExtensionRegistry.shared.command(e.id)?.key.flatMap(StartRow.symbols)
            rows.append(StartRow(image: .symbol(e.icon), title: e.title, shortcut: key) { e.open(IDEContext.current) })
        }

        let list = NSStackView(views: rows); list.orientation = .vertical; list.alignment = .leading; list.spacing = 2
        let stack = NSStackView(views: [title, folder, list]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.setCustomSpacing(20, after: folder)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: 460); width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            width, stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor), folder.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        rows.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        tiles.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor, multiplier: 0.5, constant: -4).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    func focus() {}
}

/// One action: symbol, title, its shortcut on the right; highlights on hover.
@MainActor
private final class StartRow: NSView {
    private let action: () -> Void
    private var hover = false { didSet { updateLayer() } }

    init(image: NSImage?, title: String, shortcut: String?, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 7
        let icon = NSImageView(image: image ?? NSImage()); icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = .controlAccentColor   // symbols only; real icons keep their colors
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
