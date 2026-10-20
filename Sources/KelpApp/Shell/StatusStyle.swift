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
        case .error: "exclamationmark.circle.fill"
        }
    }
    var nsColor: NSColor {
        switch self {
        case .working: .secondaryLabelColor
        case .waiting: .systemOrange
        case .done: .labelColor
        case .idle: .tertiaryLabelColor   // nothing to look at: it stays quiet
        case .hibernated: .secondaryLabelColor   // quiet, but a mark must still read (tertiary is about 2:1)
        case .exited: .secondaryLabelColor
        case .error: .systemRed
        }
    }
    var color: Color { Color(nsColor: nsColor) }
    /// Short, for rows: "Working", "Needs input"…
    var words: String {
        switch self {
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Needs your input")
        case .done: String(localized: "Done")
        case .idle: String(localized: "Ready")
        case .hibernated: String(localized: "Paused")
        case .exited: String(localized: "Ended")
        case .error: String(localized: "Failed")
        }
    }
    /// Most urgent first: what a workspace shows when it has several agents.
    static let urgency: [AgentStatus] = [.waiting, .error, .working, .done, .idle, .hibernated, .exited]
    static func mostUrgent(_ s: [AgentStatus]) -> AgentStatus? { s.min { (urgency.firstIndex(of: $0) ?? 9) < (urgency.firstIndex(of: $1) ?? 9) } }
}

/// "now", "4m", "2h", "3d": how long ago, as short as a row allows.
func shortAgo(_ d: Date?, now: Date = Date()) -> String {
    guard let d else { return "" }
    let s = max(0, Int(now.timeIntervalSince(d)))
    return s < 60 ? String(localized: "now") : s < 3600 ? String(localized: "\(s / 60)m") : s < 86400 ? String(localized: "\(s / 3600)h") : String(localized: "\(s / 86400)d")
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
    /// Working on shrinking its conversation (Claude's compaction): a slow pulse, not the spin.
    var compacting = false { didSet { if compacting != oldValue { update() } } }

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
        // VoiceOver reads the state (the spinning ring is only a layer): the same words as the tooltip.
        setAccessibilityElement(s != nil); setAccessibilityRole(.image)
        setAccessibilityLabel(compacting && s == .working ? String(localized: "Compacting its conversation") : s?.words)
        // Motion means state: spinning = working, pulsing = compacting, filled = waiting for you. With Reduce Motion a
        // still symbol says "working" instead: a ring that stopped spinning looks stuck.
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let spinning = s == .working && !compacting && !still
        ring.isHidden = !spinning; image.isHidden = spinning
        ring.removeAllAnimations(); image.layer?.removeAllAnimations(); image.alphaValue = 1
        if spinning {
            effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = NSColor.secondaryLabelColor.cgColor }
            ring.anchorPoint = CGPoint(x: 0.5, y: 0.5); ring.position = CGPoint(x: size / 2, y: size / 2)
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi; a.duration = 1; a.repeatCount = .infinity
            ring.add(a, forKey: "spin")
            return
        }
        if s == .working {
            image.image = .symbol(compacting ? "arrow.down.right.and.arrow.up.left" : "ellipsis.circle", compacting ? String(localized: "Compacting its conversation") : s?.words ?? "")
            image.symbolConfiguration = .init(pointSize: size - 2, weight: .regular); image.contentTintColor = .secondaryLabelColor
            if compacting, !still {
                image.wantsLayer = true
                let p = CABasicAnimation(keyPath: "opacity"); p.fromValue = 1; p.toValue = 0.3; p.duration = 0.9
                p.autoreverses = true; p.repeatCount = .infinity
                image.layer?.add(p, forKey: "pulse")
            }
            return
        }
        guard let s else { return }
        let seen = s == .done && !unread
        image.image = .symbol(seen ? "checkmark" : s.symbol, s.words)
        image.symbolConfiguration = .init(pointSize: seen ? size - 3 : size - 1, weight: seen ? .semibold : .regular)
        image.contentTintColor = seen ? .secondaryLabelColor : s.nsColor
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

extension Session {
    /// Ended on its own with a non-zero exit code (the daemon says so in the summary): shown red, not grey.
    var endedWithError: Bool { status == .exited && summary.hasPrefix("Ended with an error") }
}

/// Agents waiting for the user, in the order to visit them: questions and failures before finished work, oldest first.
@MainActor
enum AttentionQueue {
    static var sessions: [Session] {
        AppModel.shared.sessions
            .filter { $0.agent != "shell" && ($0.status == .waiting || $0.status == .error || ($0.status == .done && $0.unread)) }
            .sorted { ($0.status == .done ? 1 : 0, $0.statusAt ?? $0.createdAt) < ($1.status == .done ? 1 : 0, $1.statusAt ?? $1.createdAt) }
    }

    /// The one after `current` (wrapping), so pressing again walks the whole queue.
    static func next(after current: String?) -> Session? {
        let q = sessions
        guard let i = q.firstIndex(where: { $0.id == current }) else { return q.first }
        return q.count > 1 ? q[(i + 1) % q.count] : nil
    }
}
