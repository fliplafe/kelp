import AppKit
import Integrations

/// The branch's CI in a line under Commit: the latest run of each workflow, a failure first with where it broke
/// ("test › Run swift test") on a second line. Only the summary: a click opens the CI Runs panel, which has the log and the actions.
final class CIStatusRow: NSView {
    var onClick: (() -> Void)?
    private let text = NSTextField(labelWithString: ""), time = NSTextField(labelWithString: ""), place = NSTextField(labelWithString: "")
    private let top = NSStackView()
    private var failing = false, hover = false
    /// The second line under the text, past the mark. Active only once `text` is in `top` (`show`): before, they share no view.
    private lazy var placeUnderText = place.leadingAnchor.constraint(equalTo: text.leadingAnchor)

    init() {
        super.init(frame: .zero)
        text.font = .ui(12); text.lineBreakMode = .byTruncatingTail
        time.font = .ui(11); time.textColor = .tertiaryLabelColor
        place.font = .ui(11); place.textColor = .secondaryLabelColor; place.lineBreakMode = .byTruncatingMiddle
        for t in [text, place] { t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        top.spacing = 6; top.alignment = .centerY
        let col = NSStackView(views: [top, place]); col.orientation = .vertical; col.alignment = .leading; col.spacing = 2
        pin(col, inset: NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8))
        NSLayoutConstraint.activate([top.widthAnchor.constraint(equalTo: col.widthAnchor), place.trailingAnchor.constraint(lessThanOrEqualTo: col.trailingAnchor)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityElement(true); setAccessibilityRole(.button)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `latest`: one run per workflow, newest first; `failure`: where the failed one broke, once its jobs are read.
    func show(_ latest: [CIRuns.Run], failure: String?) {
        guard let run = latest.first(where: \.failed) ?? latest.first(where: { $0.status != "completed" }) ?? latest.first else { isHidden = true; return }
        isHidden = false
        failing = run.failed
        let name = latest.count > 1 && !failing && run.status == "completed" ? String(localized: "\(latest.count) workflows") : run.workflow
        text.stringValue = "\(name): \(CIRunsController.words(run.status, run.conclusion))"
        text.textColor = failing ? .labelColor : .secondaryLabelColor
        place.stringValue = failing ? failure ?? "" : ""
        place.isHidden = place.stringValue.isEmpty
        time.stringValue = CIRunsController.ago(run.createdAt)
        top.setViews([CIRunsController.mark(run.status, run.conclusion), text, NSView(), time], in: .leading)
        placeUnderText.isActive = true
        toolTip = latest.map { "\($0.workflow): \(CIRunsController.words($0.status, $0.conclusion)) · \(CIRunsController.ago($0.createdAt))" }
            .joined(separator: "\n") + (place.isHidden ? "" : "\n" + place.stringValue) + String(localized: "\n\nClick to open CI Runs")
        setAccessibilityLabel([text.stringValue, place.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = (failing ? NSColor.systemRed.withAlphaComponent(hover ? 0.18 : 0.12) : hover ? .quaternarySystemFill : .clear).cgColor
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func hitTest(_ p: NSPoint) -> NSView? { super.hitTest(p) != nil ? self : nil }   // one target, labels included
    override func mouseDown(with e: NSEvent) {}   // the click is the row's, not the panel's
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
