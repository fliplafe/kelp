import AppKit
import SwiftUI
import Core

/// One look for agent state everywhere (sidebar, tabs, panes): a spinning ring while it works, an orange ◎ when it
/// needs you, a filled ✓ when it finished and you haven't looked, a plain ✓ after, a moon when paused.
extension AgentStatus {
    var symbol: String {
        switch self {
        case .working: "circle.dotted"           // drawn as a spinning ring where there's room
        case .waiting: "record.circle"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        case .hibernated: "moon.fill"
        case .exited: "xmark.circle"
        }
    }
    var nsColor: NSColor {
        switch self {
        case .working: .secondaryLabelColor
        case .waiting: .systemOrange
        case .done: .labelColor
        case .idle, .hibernated: .tertiaryLabelColor   // nothing to look at: they stay quiet
        case .exited: .secondaryLabelColor
        }
    }
    var color: Color { Color(nsColor: nsColor) }
    /// Short, for rows: "Working", "Needs input"…
    var words: String {
        switch self {
        case .working: "Working"
        case .waiting: "Needs your input"
        case .done: "Done"
        case .idle: "Ready"
        case .hibernated: "Paused"
        case .exited: "Ended"
        }
    }
    /// Most urgent first: what a workspace shows when it has several agents.
    static let urgency: [AgentStatus] = [.waiting, .working, .done, .idle, .hibernated, .exited]
    static func mostUrgent(_ s: [AgentStatus]) -> AgentStatus? { s.min { (urgency.firstIndex(of: $0) ?? 9) < (urgency.firstIndex(of: $1) ?? 9) } }
}

/// "now", "4m", "2h", "3d": how long ago, as short as a row allows.
func shortAgo(_ d: Date?, now: Date = Date()) -> String {
    guard let d else { return "" }
    let s = max(0, Int(now.timeIntervalSince(d)))
    return s < 60 ? "now" : s < 3600 ? "\(s / 60)m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d"
}

/// A status mark for AppKit. Ready agents show none.
@MainActor
final class StatusMark: NSView {
    private let image = NSImageView()
    private let ring = CAShapeLayer()
    private let size: CGFloat
    var status: AgentStatus? { didSet { if status != oldValue { update() } } }
    /// Done and not looked at yet: the filled ✓; seen: a plain one.
    var unread = true { didSet { if unread != oldValue { update() } } }

    init(size: CGFloat = 12) {
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        image.translatesAutoresizingMaskIntoConstraints = false; addSubview(image)
        ring.fillColor = nil; ring.lineWidth = 1.5; ring.lineCap = .round
        let inset: CGFloat = 1.5
        ring.frame = CGRect(x: 0, y: 0, width: size, height: size)
        ring.path = CGPath(ellipseIn: CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset), transform: nil)
        ring.strokeEnd = 0.75
        layer?.addSublayer(ring)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size),
            image.centerXAnchor.constraint(equalTo: centerXAnchor), image.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); update() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); update() }   // animations stop when a view leaves a window

    private func update() {
        let s = status == .idle ? nil : status
        isHidden = s == nil
        toolTip = s?.words
        let spinning = s == .working
        ring.isHidden = !spinning; image.isHidden = spinning
        ring.removeAllAnimations()
        if spinning {
            effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = NSColor.secondaryLabelColor.cgColor }
            ring.anchorPoint = CGPoint(x: 0.5, y: 0.5); ring.position = CGPoint(x: size / 2, y: size / 2)
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi; a.duration = 1; a.repeatCount = .infinity
            ring.add(a, forKey: "spin")
            return
        }
        guard let s else { return }
        let seen = s == .done && !unread
        image.image = .symbol(seen ? "checkmark" : s.symbol, s.words)
        image.symbolConfiguration = .init(pointSize: seen ? size - 3 : size - 1, weight: seen ? .semibold : .regular)
        image.contentTintColor = seen ? .tertiaryLabelColor : s.nsColor
    }
}

/// Status as an SF Symbol, animated while the agent works.
struct StatusIcon: View {
    let status: AgentStatus
    var body: some View {
        Image(systemName: status == .working ? "circle.dotted" : status.symbol)
            .foregroundStyle(status.color)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: status == .working)
            .help(status.words)
    }
}
