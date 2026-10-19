import AppKit
import SwiftUI
import Core

/// One look for agent state everywhere (sidebar, tabs, inspector): SF Symbol + color + words.
extension AgentStatus {
    var symbol: String {
        switch self {
        case .working: "circle.dotted"           // shown as a spinner where there's room
        case .waiting: "questionmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        case .hibernated: "moon.zzz"
        case .exited: "xmark.circle.fill"
        }
    }
    var nsColor: NSColor {
        switch self {
        case .working: .systemBlue
        case .waiting: .systemOrange
        case .done: .systemGreen
        case .idle: .tertiaryLabelColor
        case .hibernated: .tertiaryLabelColor   // nothing to look at: paused agents stay quiet
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

/// A status mark for AppKit: a spinner while working, a colored symbol otherwise.
@MainActor
final class StatusMark: NSView {
    private let spinner = NSProgressIndicator()
    private let image = NSImageView()
    var status: AgentStatus? { didSet { if status != oldValue { update() } } }

    init(size: CGFloat = 12) {
        super.init(frame: .zero)
        spinner.style = .spinning; spinner.controlSize = .mini; spinner.isDisplayedWhenStopped = false
        image.symbolConfiguration = .init(pointSize: size - 2, weight: .semibold)
        for v in [spinner, image] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v)
            NSLayoutConstraint.activate([v.centerXAnchor.constraint(equalTo: centerXAnchor), v.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        isHidden = status == nil
        guard let s = status else { spinner.stopAnimation(nil); return }
        if s == .working { spinner.startAnimation(nil); image.isHidden = true } else {
            spinner.stopAnimation(nil); image.isHidden = false
            image.image = .symbol(s.symbol, s.words); image.contentTintColor = s.nsColor
        }
        toolTip = s.words
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

/// An agent as people recognize it — its own icon — with its state as a small dot on the corner, like the status on a
/// contact's picture: blue and pulsing while it works, orange when it needs you, green when there's something new;
/// paused agents are dimmed. Ready agents show just the icon.
@MainActor
final class AgentAvatar: NSView {
    private let icon = NSImageView()
    private let dot = CALayer()
    private let size: CGFloat

    init(size: CGFloat = 18) {
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false; addSubview(icon)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor), icon.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor), icon.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let d = round(size * 0.5)
        dot.frame = CGRect(x: size - d + 2, y: -2, width: d, height: d); dot.cornerRadius = d / 2; dot.borderWidth = 1.5
        layer?.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    func set(agent: String?, status: AgentStatus?, unread: Bool) {
        icon.image = AgentCatalog.icon(agent, size: size)
        icon.contentTintColor = .secondaryLabelColor   // symbols only; real icons keep their colors
        icon.alphaValue = status == .hibernated || status == .exited ? 0.45 : 1
        let color: NSColor? = switch status {
        case .working?: .systemBlue
        case .waiting?: .systemOrange
        case .done? where unread: .systemGreen
        default: nil
        }
        dot.isHidden = color == nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = color?.cgColor
            dot.borderColor = NSColor.windowBackgroundColor.cgColor
        }
        dot.removeAllAnimations()
        if status == .working {   // a calm pulse: alive, not alarming
            let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 1; a.toValue = 0.35
            a.duration = 0.9; a.autoreverses = true; a.repeatCount = .infinity
            dot.add(a, forKey: "pulse")
        }
        toolTip = status?.words
    }
}
