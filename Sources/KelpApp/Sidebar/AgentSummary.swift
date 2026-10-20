import AppKit
import Core

/// Over the projects: how many agents work and how many wait for you, across all of them. The second is a button to
/// the next one that waits (like ⇧⌘U). Nothing working or waiting: the line goes and the list moves up.
@MainActor
final class AgentSummary: NSStackView {
    private let workingMark = StatusMark(size: 11), waitingMark = StatusMark(size: 11)
    private let working = NSTextField(labelWithString: "")
    private let waiting = NSButton(title: "", target: nil, action: nil)
    private var height: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        working.font = .ui(11); working.textColor = .secondaryLabelColor
        waiting.isBordered = false; waiting.target = self; waiting.action = #selector(showNext)
        waiting.toolTip = String(localized: "Show the next agent that needs you (⇧⌘U)")
        workingMark.status = .working; waitingMark.status = .waiting
        setViews([workingMark, working, waitingMark, waiting], in: .leading)
        spacing = 4; setCustomSpacing(12, after: working); detachesHiddenViews = true
        let h = heightAnchor.constraint(equalToConstant: 0); h.isActive = true; height = h
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ sessions: [Session]) {
        let agents = sessions.filter { $0.agent != "shell" }
        let busy = agents.filter { $0.status == .working }.count
        let asking = agents.filter(SidebarCell.wantsYou).count   // as the projects count it
        working.stringValue = String(localized: "\(busy) working")
        waiting.attributedTitle = NSAttributedString(string: String(localized: "\(asking) need you"),
                                                     attributes: [.font: NSFont.ui(11, weight: .medium), .foregroundColor: NSColor.textOrange])
        for v in [workingMark, working] { v.isHidden = busy == 0 }
        for v in [waitingMark, waiting] { v.isHidden = asking == 0 }
        isHidden = busy + asking == 0
        height?.constant = isHidden ? 0 : TextSize.of(16)
    }

    @objc private func showNext() { if let s = AttentionQueue.sessions.first { Workbench.focus(session: s.id) } }
}
