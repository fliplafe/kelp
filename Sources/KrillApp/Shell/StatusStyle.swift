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
