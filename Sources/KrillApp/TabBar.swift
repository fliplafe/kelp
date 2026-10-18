import AppKit
import Core

/// The workspace's tab strip: one button per tab (icon, title, live agent status), close on hover, "+" menu at the end.
@MainActor
final class TabBar: NSView {
    struct Item { let id: String; let title: String; let icon: String; let status: AgentStatus?; let unread: Bool }

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onMenu: ((String) -> NSMenu?)?
    var onMove: ((Int, Int) -> Void)?
    var addMenu: () -> NSMenu = { NSMenu() }
    private let stack = NSStackView()
    private let add = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Lives in the window's title bar: empty space still drags the window.
        stack.orientation = .horizontal; stack.spacing = 2; stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.distribution = .fill; stack.detachesHiddenViews = true
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab"); add.bezelStyle = .texturedRounded; add.isBordered = false
        add.toolTip = "New agent, terminal, Changes, Files, Browser…"; add.target = self; add.action = #selector(addTapped)
        let sep = NSBox(); sep.boxType = .separator
        for v in [stack, add, sep] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -4),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), add.centerYAnchor.constraint(equalTo: centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 24),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor), sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 40)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseUp(with e: NSEvent) { if e.clickCount == 2 { window?.performZoom(nil) } }

    func set(_ items: [Item], selected: String?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, it) in items.enumerated() {
            let b = TabButton(item: it, selected: it.id == selected, index: i)
            b.onSelect = { [weak self] in self?.onSelect?(it.id) }
            b.onClose = { [weak self] in self?.onClose?(it.id) }
            b.onMenu = { [weak self] in self?.onMenu?(it.id) }
            b.onDrop = { [weak self] from in self?.onMove?(from, i) }
            stack.addArrangedSubview(b)
        }
    }

    @objc private func addTapped() {
        addMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height + 4), in: add)
    }
}

extension NSPasteboard.PasteboardType { static let krillTab = NSPasteboard.PasteboardType("dev.krill.tab") }

@MainActor
private final class TabButton: NSView, NSDraggingSource {
    var onSelect: (() -> Void)?, onClose: (() -> Void)?, onMenu: (() -> NSMenu?)?, onDrop: ((Int) -> Void)?
    private let item: TabBar.Item, selected: Bool, index: Int
    private let close = NSButton()
    private var hover = false { didSet { updateLook() } }

    init(item: TabBar.Item, selected: Bool, index: Int) {
        self.item = item; self.selected = selected; self.index = index
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 7
        let icon = NSImageView(image: NSImage(systemSymbolName: item.icon, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.contentTintColor = selected ? .labelColor : .secondaryLabelColor
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 12, weight: item.unread || selected ? .semibold : .regular)
        title.textColor = selected ? .labelColor : .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        let dot = StatusDot(status: item.status)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab"); close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 9, weight: .semibold); close.target = self; close.action = #selector(closeTapped)
        close.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [icon, title, dot, close]); row.spacing = 6; row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 26), widthAnchor.constraint(lessThanOrEqualToConstant: 240), widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            close.widthAnchor.constraint(equalToConstant: 14)
        ])
        dot.isHidden = item.status == nil
        toolTip = item.title + (item.status.map { " — \($0.label)" } ?? "")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        registerForDraggedTypes([.krillTab])
        updateLook()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateLook() {
        close.alphaValue = hover || selected ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? NSColor.controlBackgroundColor.cgColor
                : hover ? NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
            layer?.borderWidth = selected ? 0.5 : 0
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.shadowOpacity = selected ? 0.08 : 0; layer?.shadowRadius = 1.5; layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLook() }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func mouseUp(with e: NSEvent) { if e.clickCount == 1 { onSelect?() } }
    override func otherMouseUp(with e: NSEvent) { onClose?() }   // middle-click closes, like browsers
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    @objc private func closeTapped() { onClose?() }

    // reorder by dragging
    override func mouseDragged(with e: NSEvent) {
        let it = NSPasteboardItem(); it.setString(String(index), forType: .krillTab)
        let d = NSDraggingItem(pasteboardWriter: it); d.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [d], event: e, source: self)
    }
    nonisolated func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .move }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { s.draggingPasteboard.string(forType: .krillTab) != nil ? .move : [] }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let from = s.draggingPasteboard.string(forType: .krillTab).flatMap(Int.init), from != index else { return false }
        onDrop?(from); return true
    }
}

/// Agent state at a glance: blue pulse working, orange needs you, green done, grey idle.
@MainActor
final class StatusDot: NSView {
    init(status: AgentStatus?) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 3.5
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 7).isActive = true; heightAnchor.constraint(equalToConstant: 7).isActive = true
        layer?.backgroundColor = Self.color(status).cgColor
        if status == .working {
            let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 1; a.toValue = 0.3; a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
            layer?.add(a, forKey: "pulse")
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    static func color(_ s: AgentStatus?) -> NSColor {
        switch s {
        case .working: .systemBlue
        case .waiting: .systemOrange
        case .done: .systemGreen
        case .hibernated: .systemIndigo
        case .exited: .systemRed
        default: .tertiaryLabelColor
        }
    }
}
