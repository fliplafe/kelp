import AppKit

/// One editor group: its tab strip over the selected tab's content. Dropping a tab on an edge splits the group.
@MainActor
final class GroupView: NSView {
    let groupId: String
    let strip = TabStrip()
    private let container = NSView()
    private let hint = NSView()
    private weak var shown: NSView?
    private let veil = Veil()
    var onDropTab: ((String, NSRectEdge?) -> Void)?   // nil edge = into this group
    /// A terminal pane without focus, among several: it fades toward the terminal's background (Ghostty does the same).
    var dimmed = false {
        didSet {
            guard dimmed != oldValue else { return }
            veil.layer?.backgroundColor = ThemeManager.shared.terminalBackground.withAlphaComponent(0.3).cgColor
            veil.isHidden = !dimmed
        }
    }

    init(groupId: String) {
        self.groupId = groupId
        super.init(frame: .zero)
        veil.wantsLayer = true; veil.isHidden = true
        for v in [strip, container, veil] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        hint.wantsLayer = true; hint.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        hint.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor; hint.layer?.borderWidth = 1
        hint.layer?.cornerRadius = 6; hint.isHidden = true; addSubview(hint)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor), strip.leadingAnchor.constraint(equalTo: leadingAnchor), strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: strip.bottomAnchor), container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor), container.bottomAnchor.constraint(equalTo: bottomAnchor),
            veil.topAnchor.constraint(equalTo: container.topAnchor), veil.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: container.leadingAnchor), veil.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        registerForDraggedTypes([.krillTab])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ v: NSView?) {
        guard v !== shown || v?.superview !== container else { return }
        // Only if it's still here: a tab moved to another group took its view along.
        if shown?.superview === container { shown?.removeFromSuperview() }
        shown = v
        guard let v else { return }
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: container.topAnchor), v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: container.leadingAnchor), v.trailingAnchor.constraint(equalTo: container.trailingAnchor)])
    }

    // MARK: tab dropped on the content: an edge splits, the middle moves the tab here
    private func edge(_ s: NSDraggingInfo) -> NSRectEdge? {
        let p = container.convert(s.draggingLocation, from: nil), b = container.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        let fx = p.x / b.width, fy = p.y / b.height
        let m = min(fx, 1 - fx, fy, 1 - fy)
        guard m < 0.25 else { return nil }
        if m == fx { return .minX }
        if m == 1 - fx { return .maxX }
        return m == fy ? .minY : .maxY
    }
    private func showHint(_ e: NSRectEdge?) {
        var r = container.frame.insetBy(dx: 6, dy: 6)
        switch e {
        case .minX?: r.size.width /= 2
        case .maxX?: r.origin.x += r.width / 2; r.size.width /= 2
        case .minY?: r.size.height /= 2
        case .maxY?: r.origin.y += r.height / 2; r.size.height /= 2
        default: break
        }
        hint.frame = r; hint.isHidden = false
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard s.draggingPasteboard.string(forType: .krillTab) != nil else { return [] }
        showHint(edge(s)); return .move
    }
    override func draggingExited(_ s: NSDraggingInfo?) { hint.isHidden = true }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        hint.isHidden = true
        guard let id = s.draggingPasteboard.string(forType: .krillTab) else { return false }
        onDropTab?(id, edge(s)); return true
    }
}

/// Paints over the content without taking its clicks.
private final class Veil: NSView {
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
}
