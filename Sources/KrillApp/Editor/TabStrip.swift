import AppKit
import Core

extension NSPasteboard.PasteboardType { static let krillTab = NSPasteboard.PasteboardType("dev.krill.tab") }

/// A group's tab strip: icon, title, agent status, close on hover; drag to reorder, move to another group, or split.
/// The top panes' strips are the window's title bar: their empty space moves the window, as a title bar's does.
@MainActor
final class TabStrip: NSView {
    /// The title bar's height without a toolbar, so tabs line up with the traffic lights.
    static let height: CGFloat = 28
    struct Item {
        let id: String; var title: String; let icon: NSImage?; let status: AgentStatus?; var unread = false; let toolTip: String?
        var edited = false
        var meter: Double?
    }

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onMenu: ((String) -> NSMenu?)?
    var onDropTab: ((String, Int) -> Void)?        // tab id, index in this strip
    var addMenu: (() -> NSMenu)?
    var onUnzoom: (() -> Void)?
    /// This group fills the editor area (⇧⌘↩); the button says so and brings the other panes back.
    var zoomed = false { didSet { unzoom.isHidden = !zoomed } }
    private let unzoom = NSButton()
    var focused = false { didSet { if focused != oldValue { buttons.forEach { $0.groupFocused = focused } } } }
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let overflow = NSButton()
    private let add = NSButton()
    private var leadingInset: NSLayoutConstraint!, trailingInset: NSLayoutConstraint!
    private var items: [Item] = []
    private var selectedId: String?
    private var buttons: [TabButton] = []
    private let insertion = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.tabGroup); setAccessibilityLabel("Tabs")
        stack.orientation = .horizontal; stack.spacing = 1; stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        insertion.wantsLayer = true; insertion.layer?.backgroundColor = NSColor.controlAccentColor.cgColor; insertion.isHidden = true
        // Too many tabs to fit: the strip scrolls (trackpad / wheel) and the chevron lists them all, like Safari.
        overflow.image = .symbol("chevron.down", String(localized: "All Tabs")); overflow.isBordered = false; overflow.contentTintColor = .secondaryLabelColor
        overflow.symbolConfiguration = .init(pointSize: 10, weight: .semibold); overflow.toolTip = String(localized: "All tabs in this group")
        overflow.target = self; overflow.action = #selector(overflowTapped); overflow.isHidden = true
        unzoom.image = .symbol("arrow.down.right.and.arrow.up.left", String(localized: "Show All Panes")); unzoom.isBordered = false
        unzoom.contentTintColor = .controlAccentColor; unzoom.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        unzoom.toolTip = String(localized: "Show all panes (⇧⌘↩)"); unzoom.target = self; unzoom.action = #selector(unzoomTapped); unzoom.isHidden = true
        // The one way to add a tab, in each pane (like Safari's "+"); the empty workspace offers the same choices.
        add.image = .symbol("plus", String(localized: "New Tab")); add.isBordered = false; add.contentTintColor = .secondaryLabelColor
        add.symbolConfiguration = .init(pointSize: 12, weight: .medium); add.toolTip = String(localized: "New tab: an agent (⌥⌘T), a terminal (⌘T), a browser…")
        add.target = self; add.action = #selector(addTapped)
        let trailing = NSStackView(views: [unzoom, overflow, add]); trailing.spacing = 6
        scroll.documentView = stack; scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false   // in the title bar it would push the tabs down
        stack.translatesAutoresizingMaskIntoConstraints = false
        let sep = NSBox(); sep.boxType = .separator
        for v in [scroll, trailing, sep] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        addSubview(insertion)
        leadingInset = scroll.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailingInset = trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height), leadingInset, trailingInset,
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            scroll.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflow.widthAnchor.constraint(equalToConstant: 18), add.widthAnchor.constraint(equalToConstant: 22),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor), sep.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // Like Safari: tabs narrow (titles truncate, down to their minimum) before the strip has to scroll.
        // Below the split view's holding priority (250): a full strip must never move the divider.
        let fit = stack.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor); fit.priority = .init(245); fit.isActive = true
        // The stacks' own hugging and clipping resistance would beat `fit` and keep every title whole.
        stack.setHuggingPriority(.init(200), for: .horizontal); stack.setClippingResistancePriority(.init(200), for: .horizontal)
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
        clearCorners()
        super.layout()
        stack.layoutSubtreeIfNeeded()
        overflow.isHidden = stack.fittingSize.width <= scroll.bounds.width + 1
    }

    /// In the title bar, the strip keeps clear of the traffic lights and the panel toggles when its pane runs under them
    /// (the sidebar or inspector closed).
    private func clearCorners() {
        let me = convert(bounds, to: nil)
        var lead: CGFloat = 0, trail: CGFloat = 0
        // Another window with its content under the title bar (the Scratch panel): just its own buttons.
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
            .filter { !$0.isHidden }.map { $0.convert($0.bounds, to: nil) }.reduce(NSRect.null) { $0.union($1) }
        let others = window?.styleMask.contains(.fullSizeContentView) == true && !lights.isNull ? [NSRect(x: 0, y: lights.minY, width: lights.maxX + 8, height: lights.height)] : []
        for r in (window?.windowController as? MainWindowController)?.titlebarObstacles ?? others where r.intersects(me) {
            if r.midX < me.midX { lead = max(lead, r.maxX - me.minX) } else { trail = max(trail, me.maxX - r.minX) }
        }
        if leadingInset.constant != lead { leadingInset.constant = lead }
        if trailingInset.constant != -6 - trail { trailingInset.constant = -6 - trail }
    }

    /// Keeps the selected tab in view when the strip is scrolled or squeezed.
    private func revealSelected() {
        guard let i = items.firstIndex(where: { $0.id == selectedId }), buttons.indices.contains(i) else { return }
        stack.layoutSubtreeIfNeeded()
        buttons[i].scrollToVisible(buttons[i].bounds.insetBy(dx: -24, dy: 0))
    }

    @objc private func unzoomTapped() { onUnzoom?() }
    @objc private func addTapped() { addMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height + 4), in: add) }

    @objc private func overflowTapped() {
        let m = NSMenu()
        for it in items {
            let i = m.add(it.title) { [weak self] in self?.onSelect?(it.id) }
            i.image = it.icon; i.state = it.id == selectedId ? .on : .off
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height + 4), in: overflow)
    }

    /// Double-click on the empty strip: new tab, like Safari's tab bar (in the title bar, the window zooms instead).
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

/// An NSControl, not a plain view: in the title bar the window server moves the window on a drag over anything but
/// controls, whatever `mouseDownCanMoveWindow` says, so a dragged tab would take the window with it.
@MainActor
private final class TabButton: NSControl, NSDraggingSource {
    weak var strip: TabStrip?
    private var item: TabStrip.Item?
    private var selected = false
    var groupFocused = false { didSet { updateLook() } }
    private let icon = NSImageView(), title = NSTextField(labelWithString: ""), close = NSButton(), editedDot = NSImageView()
    private let mark = StatusMark(size: 12)
    private let meter = ContextMeter()
    private var hover = false { didSet { updateLook() } }

    /// Like Safari and Xcode: the close button takes the icon's place on hover; the selected tab is a quiet fill.
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 6
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        title.font = .systemFont(ofSize: 12); title.lineBreakMode = .byTruncatingTail
        close.image = .symbol("xmark", String(localized: "Close Tab")); close.toolTip = String(localized: "Close Tab (⌘W)"); close.isBordered = false; close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        close.contentTintColor = .secondaryLabelColor; close.target = self; close.action = #selector(closeTapped)
        // Unsaved changes: a dot where the close button goes (as in TextEdit's tabs); hovering shows the close button.
        editedDot.image = .symbol("circle.fill", String(localized: "Edited")); editedDot.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        editedDot.contentTintColor = .labelColor
        let slot = NSView()
        for v in [icon, close, editedDot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; slot.addSubview(v)
            NSLayoutConstraint.activate([v.centerXAnchor.constraint(equalTo: slot.centerXAnchor), v.centerYAnchor.constraint(equalTo: slot.centerYAnchor)])
        }
        let row = NSStackView(views: [slot, title, meter, mark]); row.spacing = 5; row.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 9)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 3), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220), widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            slot.widthAnchor.constraint(equalToConstant: 16), slot.heightAnchor.constraint(equalToConstant: 16)
        ])
        title.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        row.setClippingResistancePriority(.init(230), for: .horizontal)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        // VoiceOver: a tab like NSTabView's (radio button, tab subrole); the close button only exists on hover, so it's an action.
        setAccessibilityElement(true); setAccessibilityRole(.radioButton); setAccessibilitySubrole(.init(rawValue: "AXTabButton"))   // kAXTabButtonSubrole
        title.setAccessibilityElement(false); icon.setAccessibilityElement(false)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Close Tab") { [weak self] in
            MainActor.assumeIsolated { self?.closeTapped() }; return true
        }])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ it: TabStrip.Item, selected: Bool, groupFocused: Bool) {
        item = it; self.selected = selected; self.groupFocused = groupFocused
        title.stringValue = it.title; icon.image = it.icon; mark.status = it.status; mark.unread = it.unread
        meter.share = it.meter.flatMap { $0 >= 0.75 ? $0 : nil }   // only when it's worth a look
        toolTip = it.toolTip ?? it.title
        setAccessibilityLabel(it.title); setAccessibilityValue(selected)
        updateLook()
    }

    private func updateLook() {
        let edited = item?.edited == true
        close.isHidden = !hover; editedDot.isHidden = hover || !edited; icon.isHidden = hover || edited
        let active = selected && groupFocused
        title.textColor = selected ? .labelColor : .secondaryLabelColor
        title.font = .systemFont(ofSize: 12, weight: active ? .medium : .regular)
        icon.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill = selected ? (groupFocused ? 0.12 : 0.07) : hover ? 0.05 : 0
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(fill).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLook() }
    /// The whole tab takes the click, label and icon included: in the title bar they would move the window instead.
    override func hitTest(_ p: NSPoint) -> NSView? {
        guard let v = super.hitTest(p) else { return nil }
        return v.isDescendant(of: close) ? v : self
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func mouseDown(with e: NSEvent) { if let id = item?.id { strip?.onSelect?(id) } }
    override func accessibilityPerformPress() -> Bool { if let id = item?.id { strip?.onSelect?(id) }; return true }
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

/// A small ring: how full an agent's conversation is (amber from 75 %, red from 90 %).
@MainActor
final class ContextMeter: NSView {
    private let track = CAShapeLayer(), fill = CAShapeLayer()
    var share: Double? { didSet { isHidden = share == nil; update() } }
    init() {
        super.init(frame: .zero)
        wantsLayer = true; isHidden = true
        let path = CGMutablePath()   // from the top, clockwise (the layer's y goes up)
        path.addArc(center: CGPoint(x: 6, y: 6), radius: 4.5, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [track, fill] { l.path = path; l.fillColor = nil; l.lineWidth = 2; layer?.addSublayer(l) }
        fill.lineCap = .round
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 12), heightAnchor.constraint(equalToConstant: 12)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); update() }
    private func update() {
        guard let share else { return }
        toolTip = String(localized: "Context \(Int(share * 100)) % full")
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.tertiaryLabelColor.cgColor
            fill.strokeColor = (share >= 0.9 ? NSColor.systemRed : .systemOrange).cgColor
        }
        fill.strokeEnd = min(1, share)
    }
}
