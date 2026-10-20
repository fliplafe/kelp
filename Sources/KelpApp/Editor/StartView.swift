import AppKit
import GitKit
import Core
import WorkbenchKit

/// An empty workspace: where it is, a field for the default agent's first task, and what can be opened here, one
/// click each (like Xcode's welcome window) — the installed agents, a terminal, and whatever extensions add (the browser…).
@MainActor
final class StartView: NSView, NSTextFieldDelegate {
    var onAgent: ((String) -> Void)?
    /// The default agent, started with what was typed (the workspace takes its name from it).
    var onPrompt: ((String, String) -> Void)?
    var onOpen: ((String) -> Void)?
    private let prompt = NSTextField()
    private let def = AgentCatalog.defaultAgent

    init(worktree w: Worktree) {
        super.init(frame: .zero)
        let repo = AppModel.shared.repo(w.repoId)
        let icon = NSImageView(image: repo.map { ProjectIcon.image(for: $0.path) } ?? .symbol("folder"))
        icon.imageScaling = .scaleProportionallyUpOrDown; icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: w.displayName)
        title.font = .systemFont(ofSize: 20, weight: .semibold); title.lineBreakMode = .byTruncatingTail; title.alignment = .center
        // The window bar shows the folder; a remote project's host and path are said here, the bar has the local stand-in.
        let folder = NSTextField(labelWithString: RemoteHost.of(w.path).map { "\($0.host):\($0.path)" } ?? "")
        folder.font = .systemFont(ofSize: 13); folder.textColor = .secondaryLabelColor; folder.lineBreakMode = .byTruncatingMiddle
        folder.isHidden = folder.stringValue.isEmpty

        // The default agent first, then the others (two columns when there are many: people often have a dozen).
        let agents = AgentCatalog.installed(AgentCatalog.all).sorted { ($0.id == def ? 0 : 1, $0.name) < ($1.id == def ? 0 : 1, $1.name) }
        // In two columns there's no room for "Default" beside the name (first place and ⌥⌘T say it); the name always fits.
        let tiles = agents.map { a in
            StartRow(image: AgentCatalog.icon(a.id, size: 20), title: a.name, detail: a.id == def && agents.count <= 5 ? String(localized: "Default") : nil,
                     shortcut: a.id == def ? "⌥⌘T" : nil) { [weak self] in self?.onAgent?(a.id) }
        }
        var rows: [NSView] = []
        if agents.isEmpty {
            let none = NSTextField(wrappingLabelWithString: String(localized: "No agent found. Install Claude Code or another agent CLI — Kelp picks it up when you come back."))
            none.textColor = .secondaryLabelColor
            rows.append(StartView.padded(none))
        } else if tiles.count > 5 {
            let grid = NSGridView(numberOfColumns: 2, rows: 0); grid.columnSpacing = 4; grid.rowSpacing = 0
            for i in stride(from: 0, to: tiles.count, by: 2) {
                grid.addRow(with: [tiles[i], i + 1 < tiles.count ? tiles[i + 1] : NSGridCell.emptyContentView])
            }
            rows.append(grid)
        } else {
            rows += tiles
        }
        var others = [StartRow(image: .symbol("terminal"), title: String(localized: "Terminal"), shortcut: "⌘T") { [weak self] in self?.onOpen?("terminal:") }]
        // Changes live in Source Control; the rest of what extensions open is offered here.
        for e in ExtensionRegistry.shared.all.editors where e.id != "git.review" {
            let key = ExtensionRegistry.shared.command(e.id)?.key.flatMap(StartRow.symbols)
            others.append(StartRow(image: .symbol(e.icon), title: e.title, shortcut: key) { e.open(IDEContext.current) })
        }
        let card = StartCard(rows: rows, others: others)

        let open = NSTextField(labelWithString: String(localized: "Open"))
        open.font = .ui(11, weight: .semibold); open.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: String(localized: "A file, an agent or a command: ⌘P"))
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor

        var views: [NSView] = [icon, title, folder]
        let field = agents.contains { $0.id == def } ? promptField() : nil
        if let field { views.append(field) }
        views += [open, card, hint]
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(14, after: icon); stack.setCustomSpacing(24, after: folder.isHidden ? title : folder)
        if let field { stack.setCustomSpacing(22, after: field) }
        stack.setCustomSpacing(6, after: open); stack.setCustomSpacing(14, after: card)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: 460); width.priority = .defaultHigh
        // A little above the middle; in a low window it starts at the top instead of going under it.
        let middle = stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30); middle.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), middle, stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),
            width, stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor), folder.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor), open.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 4)
        ])
        if let field { field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        if tiles.count > 5 { tiles.forEach { $0.widthAnchor.constraint(equalTo: card.widthAnchor, multiplier: 0.5, constant: -6).isActive = true } }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The default agent's icon and a field: Return starts the agent with the text.
    private func promptField() -> NSView {
        let name = AgentCatalog.all.first { $0.id == def }?.name ?? def
        prompt.placeholderString = String(localized: "What should \(name) do? Return starts it")
        prompt.isBordered = false; prompt.drawsBackground = false; prompt.focusRingType = .none; prompt.font = .systemFont(ofSize: 14)
        prompt.lineBreakMode = .byTruncatingTail; prompt.delegate = self
        prompt.setAccessibilityLabel(String(localized: "First task for \(name)"))
        let icon = NSImageView(image: AgentCatalog.icon(def, size: 18) ?? NSImage())
        let row = NSStackView(views: [icon, prompt]); row.spacing = 10; row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let box = StartBox(radius: 10, fill: 0.05)
        row.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(row)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 40), icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor), row.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        return box
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        let text = prompt.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onPrompt?(def, text) }
        return true
    }

    func focus() { if prompt.superview != nil { window?.makeFirstResponder(prompt) } }

    static func padded(_ v: NSView) -> NSView {
        let p = NSStackView(views: [v]); p.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return p
    }
}

/// A rounded box in the system's grouped style: a soft fill and a hairline.
@MainActor
private final class StartBox: NSView {
    private let radius: CGFloat, fill: CGFloat
    init(radius: CGFloat, fill: CGFloat) { self.radius = radius; self.fill = fill; super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = radius; layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(fill).cgColor
    }
}

/// The choices in one grouped box, like a Settings list: the agents, a line, then the terminal and the rest.
@MainActor
private final class StartCard: NSView {
    init(rows: [NSView], others: [NSView]) {
        super.init(frame: .zero)
        let box = StartBox(radius: 12, fill: 0.035)
        var views: [NSView] = []
        for (i, r) in (rows + others).enumerated() {
            if i > 0 {
                let sep = NSBox(); sep.boxType = .separator
                views.append(sep)
            }
            views.append(r)
        }
        let list = NSStackView(views: views); list.orientation = .vertical; list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        for v in [box, list] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor), box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor), box.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor), list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: topAnchor), list.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for v in views {
            if v is NSBox { v.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -40).isActive = true }   // inset like grouped lists
            else if !(v is NSGridView) { v.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -8).isActive = true }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One action: symbol, title, a detail and its shortcut on the right; highlights on hover.
@MainActor
private final class StartRow: NSView {
    private let action: () -> Void
    private var hover = false { didSet { updateLayer() } }

    init(image: NSImage?, title: String, detail: String? = nil, shortcut: String?, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 8
        let icon = NSImageView(image: image ?? NSImage()); icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor   // symbols only; real icons keep their colors
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let more = NSTextField(labelWithString: detail ?? ""); more.textColor = .secondaryLabelColor; more.font = .systemFont(ofSize: 12)
        more.lineBreakMode = .byTruncatingTail; more.setContentCompressionResistancePriority(.init(240), for: .horizontal)   // the name wins
        let key = NSTextField(labelWithString: shortcut ?? ""); key.textColor = .secondaryLabelColor; key.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [icon, label, NSView(), more, key]); row.spacing = 10; row.detachesHiddenViews = true
        more.isHidden = detail == nil; key.isHidden = shortcut == nil
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36), icon.widthAnchor.constraint(equalToConstant: 22),
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
            layer?.backgroundColor = hover ? NSColor.labelColor.withAlphaComponent(0.07).cgColor : NSColor.clear.cgColor
        }
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { action() } }
    override func accessibilityPerformPress() -> Bool { action(); return true }

    /// "shift+cmd+b" → "⇧⌘B".
    static func symbols(_ key: String) -> String? {
        guard let k = KeySpec(key) else { return nil }
        var s = ""
        if k.mods.contains(.control) { s += "⌃" }
        if k.mods.contains(.option) { s += "⌥" }
        if k.mods.contains(.shift) { s += "⇧" }
        if k.mods.contains(.command) { s += "⌘" }
        return s + k.key.uppercased()
    }
}

extension Worktree {
    /// The name people see: their own, or the branch.
    var displayName: String { note.isEmpty ? branch : note }
}
