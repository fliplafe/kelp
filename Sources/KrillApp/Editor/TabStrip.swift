import AppKit
import Core

extension NSPasteboard.PasteboardType { static let krillTab = NSPasteboard.PasteboardType("dev.krill.tab") }

/// A group's tab strip: icon, title, agent status, close on hover; drag to reorder, move to another group, or split.
@MainActor
final class TabStrip: NSView {
    struct Item { let id: String; let title: String; let icon: NSImage?; let status: AgentStatus?; let toolTip: String? }

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onMenu: ((String) -> NSMenu?)?
    var onDropTab: ((String, Int) -> Void)?        // tab id, index in this strip
    var addMenu: (() -> NSMenu)?
    var focused = false { didSet { if focused != oldValue { buttons.forEach { $0.groupFocused = focused } } } }
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let overflow = NSButton()
    private var items: [Item] = []
    private var selectedId: String?
    private var buttons: [TabButton] = []
    private let insertion = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal; stack.spacing = 1; stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        insertion.wantsLayer = true; insertion.layer?.backgroundColor = NSColor.controlAccentColor.cgColor; insertion.isHidden = true
        // Too many tabs to fit: the strip scrolls (trackpad / wheel) and the chevron lists them all, like Safari.
        overflow.image = .symbol("chevron.down", "All Tabs"); overflow.isBordered = false; overflow.contentTintColor = .secondaryLabelColor
        overflow.symbolConfiguration = .init(pointSize: 10, weight: .semibold); overflow.toolTip = "All tabs in this group"
        overflow.target = self; overflow.action = #selector(overflowTapped); overflow.isHidden = true
        scroll.documentView = stack; scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
        stack.translatesAutoresizingMaskIntoConstraints = false
        let sep = NSBox(); sep.boxType = .separator
        for v in [scroll, overflow, sep] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        addSubview(insertion)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            scroll.trailingAnchor.constraint(equalTo: overflow.leadingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            overflow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), overflow.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflow.widthAnchor.constraint(equalToConstant: 18),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor), sep.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        registerForDraggedTypes([.krillTab])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    override var wantsUpdateLayer: Bool { true }

    func set(_ items: [Item], selected: String?) {
        // Reuse buttons by position: tabs change titles and status far more often than they move.
        while buttons.count > items.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < items.count {
            let b = TabButton(); b.strip = self; buttons.append(b); stack.addArrangedSubview(b)
        }
        for (b, it) in zip(buttons, items) { b.set(it, selected: it.id == selected, groupFocused: focused) }
        self.items = items; selectedId = selected
        needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.revealSelected() }
    }

    override func layout() {
        super.layout()
        stack.layoutSubtreeIfNeeded()
        overflow.isHidden = stack.fittingSize.width <= scroll.bounds.width + 1
    }

    /// Keeps the selected tab in view when the strip is scrolled or squeezed.
    private func revealSelected() {
        guard let i = items.firstIndex(where: { $0.id == selectedId }), buttons.indices.contains(i) else { return }
        stack.layoutSubtreeIfNeeded()
        buttons[i].scrollToVisible(buttons[i].bounds.insetBy(dx: -24, dy: 0))
    }

    @objc private func overflowTapped() {
        let m = NSMenu()
        for it in items {
            let i = m.add(it.title) { [weak self] in self?.onSelect?(it.id) }
            i.image = it.icon; i.state = it.id == selectedId ? .on : .off
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height + 4), in: overflow)
    }

    /// Double-click on the empty strip: new tab, like Safari's tab bar.
    override func mouseDown(with e: NSEvent) {
        guard e.clickCount == 2, let m = addMenu?() else { super.mouseDown(with: e); return }
        m.popUp(positioning: nil, at: convert(e.locationInWindow, from: nil), in: self)
    }

    // MARK: drops between tabs
    private func index(at p: NSPoint) -> Int {
        let x = stack.convert(p, from: nil).x
        return buttons.firstIndex { $0.frame.midX > x } ?? buttons.count
    }
    private func showInsertion(_ i: Int) {
        let local = i < buttons.count ? buttons[i].frame.minX - 1 : (buttons.last?.frame.maxX ?? 6)
        let x = convert(NSPoint(x: local, y: 0), from: stack).x
        insertion.frame = NSRect(x: x, y: 4, width: 2, height: bounds.height - 8); insertion.isHidden = false
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard s.draggingPasteboard.string(forType: .krillTab) != nil else { return [] }
        showInsertion(index(at: s.draggingLocation)); return .move
    }
    override func draggingExited(_ s: NSDraggingInfo?) { insertion.isHidden = true }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        insertion.isHidden = true
        guard let id = s.draggingPasteboard.string(forType: .krillTab) else { return false }
        onDropTab?(id, index(at: s.draggingLocation)); return true
    }
}

@MainActor
private final class TabButton: NSView, NSDraggingSource {
    weak var strip: TabStrip?
    private var item: TabStrip.Item?
    private var selected = false
    var groupFocused = false { didSet { updateLook() } }
    private let icon = NSImageView(), title = NSTextField(labelWithString: ""), close = NSButton()
    private let mark = StatusMark(size: 12)
    private var hover = false { didSet { updateLook() } }
    private let underline = NSView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 6
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        title.font = .systemFont(ofSize: 12); title.lineBreakMode = .byTruncatingTail
        close.image = .symbol("xmark", "Close Tab"); close.isBordered = false; close.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        close.contentTintColor = .secondaryLabelColor; close.target = self; close.action = #selector(closeTapped)
        underline.wantsLayer = true; underline.layer?.backgroundColor = NSColor.controlAccentColor.cgColor; underline.layer?.cornerRadius = 1
        let row = NSStackView(views: [icon, title, mark, close]); row.spacing = 5; row.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 5)
        for v in [row, underline] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 3), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220), widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            close.widthAnchor.constraint(equalToConstant: 14),
            underline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), underline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor), underline.heightAnchor.constraint(equalToConstant: 2)
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ it: TabStrip.Item, selected: Bool, groupFocused: Bool) {
        item = it; self.selected = selected; self.groupFocused = groupFocused
        title.stringValue = it.title; icon.image = it.icon; mark.status = it.status
        toolTip = it.toolTip ?? it.title
        updateLook()
    }

    private func updateLook() {
        close.alphaValue = hover || selected ? 1 : 0
        title.textColor = selected ? .labelColor : .secondaryLabelColor
        title.font = .systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        icon.contentTintColor = selected ? .labelColor : .secondaryLabelColor
        underline.isHidden = !(selected && groupFocused)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.6).cgColor
                : hover ? NSColor.quaternaryLabelColor.withAlphaComponent(0.2).cgColor : NSColor.clear.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLook() }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func mouseDown(with e: NSEvent) { if let id = item?.id { strip?.onSelect?(id) } }
    override func otherMouseUp(with e: NSEvent) { closeTapped() }
    override func menu(for event: NSEvent) -> NSMenu? { item.flatMap { strip?.onMenu?($0.id) } }
    @objc private func closeTapped() { if let id = item?.id { strip?.onClose?(id) } }

    override func mouseDragged(with e: NSEvent) {
        guard let id = item?.id else { return }
        let p = NSPasteboardItem(); p.setString(id, forType: .krillTab)
        let d = NSDraggingItem(pasteboardWriter: p); d.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [d], event: e, source: self)
    }
    nonisolated func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .move }
}
