import AppKit
import Core

struct AgentEvent { let date: Date; let session: Session; let status: AgentStatus }

/// Kanban of every agent across projects, plus a feed of status changes.
@MainActor
final class DashboardController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = DashboardController()
    static var events: [AgentEvent] = []   // filled by AppModel status events

    private var window: NSWindow?
    private let columns: [(String, [AgentStatus], NSColor)] = [
        ("Needs you", [.waiting], .systemOrange), ("Working", [.working], .systemBlue), ("Done", [.done], .systemGreen), ("Idle", [.idle], .systemGray),
    ]
    private var stacks: [NSStackView] = []
    private let feed = NSTableView()
    private let filter = NSSearchField()

    func show() {
        if window == nil { build() }
        reload(); window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let board = NSStackView(); board.orientation = .horizontal; board.distribution = .fillEqually; board.alignment = .top; board.spacing = 12
        for (name, _, color) in columns {
            let title = NSTextField(labelWithString: name); title.font = .systemFont(ofSize: 13, weight: .semibold); title.textColor = color
            let cards = NSStackView(); cards.orientation = .vertical; cards.alignment = .leading; cards.spacing = 8
            let col = NSStackView(views: [title, cards]); col.orientation = .vertical; col.alignment = .leading; col.spacing = 10
            col.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            col.wantsLayer = true; col.layer?.cornerRadius = 10; col.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
            stacks.append(cards); board.addArrangedSubview(col)
        }
        let boardScroll = NSScrollView(); boardScroll.documentView = board; boardScroll.hasVerticalScroller = true; boardScroll.drawsBackground = false
        board.translatesAutoresizingMaskIntoConstraints = false
        boardScroll.contentView.translatesAutoresizingMaskIntoConstraints = false

        let c = NSTableColumn(identifier: .init("e")); feed.addTableColumn(c); feed.headerView = nil
        feed.dataSource = self; feed.delegate = self; feed.rowHeight = 20; feed.target = self; feed.doubleAction = #selector(openEvent)
        let fs = NSScrollView(); fs.documentView = feed; fs.hasVerticalScroller = true
        filter.placeholderString = "Filter events"; filter.target = self; filter.action = #selector(refilter)
        let feedTitle = NSTextField(labelWithString: "Activity"); feedTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        let root = NSView()
        for v in [boardScroll, feedTitle, filter, fs] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            boardScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), boardScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            boardScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), boardScroll.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.58),
            board.topAnchor.constraint(equalTo: boardScroll.contentView.topAnchor), board.leadingAnchor.constraint(equalTo: boardScroll.contentView.leadingAnchor),
            board.widthAnchor.constraint(equalTo: boardScroll.contentView.widthAnchor),
            feedTitle.topAnchor.constraint(equalTo: boardScroll.bottomAnchor, constant: 12), feedTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            filter.centerYAnchor.constraint(equalTo: feedTitle.centerYAnchor), filter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), filter.widthAnchor.constraint(equalToConstant: 220),
            fs.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8), fs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            fs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), fs.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Agents"; w.contentView = root; w.isReleasedWhenClosed = false; w.setFrameAutosaveName("dashboard"); w.center()
        window = w
        AppModel.shared.onChange.append { [weak self] in if self?.window?.isVisible == true { self?.reload() } }
    }

    private func reload() {
        let all = AppModel.shared.sessions.filter { $0.status != .exited && $0.agent != "shell" && $0.agent != "custom" }
        for (i, col) in columns.enumerated() {
            stacks[i].arrangedSubviews.forEach { $0.removeFromSuperview() }
            let items = all.filter { col.1.contains($0.status) }
            if items.isEmpty { let e = NSTextField(labelWithString: "—"); e.textColor = .tertiaryLabelColor; stacks[i].addArrangedSubview(e) }
            for s in items { stacks[i].addArrangedSubview(card(s, color: col.2)) }
        }
        feed.reloadData()
    }

    private func card(_ s: Session, color: NSColor) -> NSView {
        let wt = AppModel.shared.worktree(s.worktreeId)
        let repo = AppModel.shared.repo(wt?.repoId)
        let t = NSTextField(labelWithString: s.displayTitle); t.font = .systemFont(ofSize: 12, weight: .semibold); t.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: "\(repo?.name ?? "") · \(wt?.branch ?? "") · \(s.agent ?? "")"); sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingMiddle
        let sum = NSTextField(wrappingLabelWithString: s.summary); sum.font = .systemFont(ofSize: 11); sum.maximumNumberOfLines = 3
        let b = NSButton(title: "Open", target: self, action: #selector(openCard(_:))); b.bezelStyle = .rounded; b.controlSize = .small; b.identifier = .init(s.id)
        let v = NSStackView(views: [t, sub] + (s.summary.isEmpty ? [] : [sum]) + [b]); v.orientation = .vertical; v.alignment = .leading; v.spacing = 4
        v.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        v.wantsLayer = true; v.layer?.cornerRadius = 8; v.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        v.layer?.borderWidth = 1; v.layer?.borderColor = (s.unread ? color : NSColor.separatorColor).cgColor
        v.widthAnchor.constraint(equalToConstant: 230).isActive = true
        for x in [t, sub, sum] { x.preferredMaxLayoutWidth = 210 }
        return v
    }

    @objc private func openCard(_ b: NSButton) { if let id = b.identifier?.rawValue { (NSApp.delegate as? AppDelegate)?.openSession(id); NSApp.mainWindow?.makeKeyAndOrderFront(nil) } }

    private var shown: [AgentEvent] {
        let q = filter.stringValue.lowercased()
        let e = Self.events.reversed()
        return q.isEmpty ? Array(e) : e.filter { "\($0.session.displayTitle) \($0.status.label) \($0.session.summary)".lowercased().contains(q) }
    }
    @objc private func refilter() { feed.reloadData() }
    func numberOfRows(in t: NSTableView) -> Int { shown.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let e = shown[row]
        let f = DateFormatter(); f.timeStyle = .short
        let l = NSTextField(labelWithString: "\(f.string(from: e.date))   \(e.session.displayTitle) — \(e.status.label)\(e.session.summary.isEmpty ? "" : ": " + e.session.summary)")
        l.lineBreakMode = .byTruncatingTail; l.font = .systemFont(ofSize: 12)
        return l
    }
    @objc private func openEvent() { if feed.clickedRow >= 0 { (NSApp.delegate as? AppDelegate)?.openSession(shown[feed.clickedRow].session.id) } }
}
