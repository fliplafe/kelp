import AppKit
import SwiftUI
import Core
import WorkbenchKit

/// Over the projects, one line that never changes height: the most urgent agent that needs you (who, where, what) and
/// how many more; a click lists them all. Nothing needs you: how many work. No agents at all: the line goes.
@MainActor
final class AgentSummary: NSView {
    private let mark = StatusMark(size: 14)
    private let text = NSTextField(labelWithString: "")
    private let more = NSTextField(labelWithString: "")
    private let chevron = NSImageView(image: .symbol("chevron.down"))
    private var height: NSLayoutConstraint?
    private let app: AppModel
    private var shown: [Session] = []
    private let popover = NSPopover()
    private var settleTimer: Timer?

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 8
        text.font = .ui(12)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.usesSingleLineMode = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        more.font = .uiDigits(11, weight: .regular); more.textColor = .secondaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold); chevron.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [mark, text, more, chevron])
        row.spacing = 6
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        let h = heightAnchor.constraint(equalToConstant: 0); height = h
        NSLayoutConstraint.activate([
            h, row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        popover.behavior = .transient; popover.animates = false
        setAccessibilityElement(true); setAccessibilityRole(.button)
        track(owner: self) { [app] in app.sessions } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [app] in app.workbench.focusedTab } changed: { [weak self] _ in self?.update() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        var inbox = Inbox(queue: AttentionQueue(app).sessions)
        let tab = app.workbench.focusedTab ?? ""
        if TabURI.scheme(tab) == "session" { inbox.viewing = [TabURI.body(tab)] }
        shown = inbox.shown
        settleTimer?.invalidate(); settleTimer = nil
        if let due = inbox.settlesAt {
            settleTimer = Timer.scheduledTimer(withTimeInterval: due.timeIntervalSinceNow, repeats: false) { [weak self] _ in   // main run loop
                MainActor.assumeIsolated { self?.update() }
            }
        }
        let agents = app.sessions.filter { $0.agent != "shell" && $0.status != .exited }
        isHidden = agents.isEmpty && shown.isEmpty
        height?.constant = isHidden ? 0 : TextSize.of(28)
        layer?.backgroundColor = shown.isEmpty ? nil : NSColor.labelColor.withAlphaComponent(0.045).cgColor
        more.isHidden = shown.count < 2; chevron.isHidden = shown.isEmpty
        if let s = shown.first {
            mark.status = SidebarCell.shownStatus(s); mark.unread = s.unread
            text.attributedStringValue = Self.line(s, app: app)
            more.stringValue = "+\(shown.count - 1)"
            toolTip = text.stringValue + "\n" + String(localized: "Show the agents that need you (⇧⌘U goes to the next one)")
            setAccessibilityLabel(String(localized: "\(shown.count) need you") + ": " + text.stringValue)
        } else {
            let busy = agents.filter { $0.status == .working }.count
            mark.status = busy > 0 ? .working : nil
            text.attributedStringValue = NSAttributedString(string: busy > 0 ? String(localized: "\(busy) working") : "",
                                                            attributes: [.font: NSFont.ui(11), .foregroundColor: NSColor.secondaryLabelColor])
            toolTip = nil; setAccessibilityLabel(text.stringValue)
            if popover.isShown { popover.close() }
        }
    }

    /// "**Claude** Needs permission to use Bash · fix-login": what happened before where, which the narrow line cuts first.
    static func line(_ s: Session, app: AppModel) -> NSAttributedString {
        let cut = NSMutableParagraphStyle(); cut.lineBreakMode = .byTruncatingTail
        let name: [NSAttributedString.Key: Any] = [.font: NSFont.ui(12, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: cut]
        let t = NSMutableAttributedString(string: app.catalog.displayName(s), attributes: name)
        let place = app.worktree(s.worktreeId)?.displayName ?? ""
        let what = s.summary.isEmpty ? SidebarCell.shownStatus(s).words : s.summary   // paused with news: "Done", not "Paused"
        t.append(NSAttributedString(string: "  " + what + (place.isEmpty ? "" : " · " + place),
                                    attributes: [.font: NSFont.ui(12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: cut]))
        return t
    }

    override func mouseDown(with e: NSEvent) { toggle() }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }

    private func toggle() {
        guard !shown.isEmpty else { return }
        if popover.isShown { popover.close(); return }
        let app = self.app
        let host = NSHostingController(rootView: InboxView(app: app) { [weak self] in self?.popover.close() })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

/// The list behind the line: questions and failures, then finished work; a click opens the agent.
private struct InboxView: View {
    let app: AppModel
    let close: () -> Void

    var body: some View {
        let all = AttentionQueue(app).sessions
        let asking = all.filter { SidebarCell.shownStatus($0) != .done }, done = all.filter { SidebarCell.shownStatus($0) == .done }
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Needs You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !done.isEmpty {
                    Button("Mark Finished as Read") {
                        for s in done { Task { await app.call(SessionMarkRead(id: s.id)) } }
                        if asking.isEmpty { close() }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            group(String(localized: "Needs a Decision"), asking)
            group(String(localized: "Done"), done)
        }
        .padding(8).frame(width: 300)
    }

    @ViewBuilder private func group(_ title: String, _ sessions: [Session]) -> some View {
        if !sessions.isEmpty {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.top, 6)
            ForEach(sessions, id: \.id) { s in row(s) }
        }
    }

    private func row(_ s: Session) -> some View {
        let w = app.worktree(s.worktreeId)
        return Button { app.workbench.focus(session: s.id); close() } label: {
            HStack(alignment: .top, spacing: 8) {
                if let icon = app.catalog.icon(s.agent, size: 16) { Image(nsImage: icon).frame(width: 16, height: 16) }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(app.catalog.displayName(s)).fontWeight(s.unread ? .semibold : .regular).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(shortAgo(s.statusAt ?? s.createdAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        StatusIcon(status: SidebarCell.shownStatus(s)).font(.caption)
                    }
                    Text([app.repo(w?.repoId)?.name, w?.displayName].compactMap { $0 }.joined(separator: " › "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(s.summary.isEmpty ? SidebarCell.shownStatus(s).words : s.summary).font(.callout).lineLimit(2)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
