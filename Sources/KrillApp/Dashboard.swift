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
    private let usage = NSStackView()
    private var usageTimer: Timer?

    func show() {
        if window == nil { build() }
        reload(); loadUsage(); window?.makeKeyAndOrderFront(nil)
        usageTimer?.invalidate()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { if self?.window?.isVisible == true { self?.loadUsage() } } }
    }

    /// Claude: current 5-hour block (cost estimate, reset time), today, 7 days. Codex: rate-limit windows.
    private func loadUsage() {
        Task {
            guard let u = await AppModel.shared.call("usage.get") else { return }
            usage.arrangedSubviews.forEach { $0.removeFromSuperview() }
            func num(_ v: JSONValue?) -> Double { if case .double(let d)? = v { return d }; return Double(v?.int ?? 0) }
            func money(_ v: Double) -> String { String(format: "$%.2f", v) }
            func tokens(_ b: JSONValue?) -> String {
                let t = num(b?["input"]) + num(b?["output"]) + num(b?["cacheWrite"]) + num(b?["cacheRead"])
                return t > 1e6 ? String(format: "%.1fM tokens", t / 1e6) : String(format: "%.0fK tokens", t / 1e3)
            }
            func until(_ ts: Double) -> String {
                let s = max(0, ts - Date().timeIntervalSince1970); return s < 60 ? "now" : "in \(Int(s) / 3600)h \(Int(s) % 3600 / 60)m"
            }
            for c in u["claude"]?.array ?? [] {
                var lines = ["Claude · \(c["account"]?.string ?? "")"]
                if let b = c["block"] { lines.append("5-hour window: \(money(num(b["cost"]))) · \(tokens(b)) · resets \(until(num(b["end"])))") }
                else { lines.append("No activity in the current 5-hour window") }
                lines.append("Today \(money(num(c["today"]?["cost"])))   ·   7 days \(money(num(c["week"]?["cost"])))")
                usage.addArrangedSubview(card(lines))
            }
            for x in u["codex"]?.array ?? [] {
                var lines = ["Codex"]
                let now = Date().timeIntervalSince1970
                for (name, used, reset) in [("Short window", "primaryUsedPercent", "primaryResetsAt"), ("Weekly", "secondaryUsedPercent", "secondaryResetsAt")] where x[used] != nil {
                    // A window that already reset says nothing about now.
                    if x[reset] != nil, num(x[reset]) < now { lines.append("\(name): reset since the last session") }
                    else { lines.append("\(name): \(Int(num(x[used])))% used · resets \(until(num(x[reset])))") }
                }
                let seen = Date(timeIntervalSince1970: num(x["observedAt"]))
                lines.append("as of \(RelativeDateTimeFormatter().localizedString(for: seen, relativeTo: Date()))")
                if lines.count == 1 { lines.append("No recent limit data") }
                usage.addArrangedSubview(card(lines))
            }
            if usage.arrangedSubviews.isEmpty { usage.addArrangedSubview(card(["Usage", "No Claude Code or Codex history found on this Mac"])) }
        }
    }

    private func card(_ lines: [String]) -> NSView {
        let v = NSStackView(views: lines.enumerated().map { i, l in
            let t = NSTextField(labelWithString: l); t.font = i == 0 ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 11)
            t.textColor = i == 0 ? .labelColor : .secondaryLabelColor; return t
        })
        v.orientation = .vertical; v.alignment = .leading; v.spacing = 3; v.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        v.wantsLayer = true; v.layer?.cornerRadius = 8; v.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        v.toolTip = "Costs are estimates from a local price table; limits are read from the agents' own files."
        return v
    }

    private func build() {
        let board = NSStackView(); board.orientation = .horizontal; board.distribution = .fillEqually; board.alignment = .top; board.spacing = 12
        for (name, _, color) in columns {
            let title = NSTextField(labelWithString: name); title.font = .systemFont(ofSize: 13, weight: .semibold); title.textColor = color
            let cards = NSStackView(); cards.orientation = .vertical; cards.alignment = .leading; cards.spacing = 8
            let col = NSStackView(views: [title, cards]); col.orientation = .vertical; col.alignment = .leading; col.spacing = 10
            col.setHuggingPriority(.defaultLow, for: .horizontal)
            col.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            col.wantsLayer = true; col.layer?.cornerRadius = 10; col.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
            stacks.append(cards); board.addArrangedSubview(col)
        }
        let boardScroll = NSScrollView(); boardScroll.hasVerticalScroller = true; boardScroll.drawsBackground = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false; boardScroll.documentView = doc
        board.translatesAutoresizingMaskIntoConstraints = false; doc.addSubview(board)
        NSLayoutConstraint.activate([
            board.topAnchor.constraint(equalTo: doc.topAnchor), board.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            board.trailingAnchor.constraint(equalTo: doc.trailingAnchor), board.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: boardScroll.contentView.widthAnchor),
        ])

        let c = NSTableColumn(identifier: .init("e")); feed.addTableColumn(c); feed.headerView = nil
        feed.dataSource = self; feed.delegate = self; feed.rowHeight = 20; feed.target = self; feed.doubleAction = #selector(openEvent)
        let fs = NSScrollView(); fs.documentView = feed; fs.hasVerticalScroller = true
        filter.placeholderString = "Filter events"; filter.target = self; filter.action = #selector(refilter)
        let feedTitle = NSTextField(labelWithString: "Activity"); feedTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        usage.orientation = .horizontal; usage.spacing = 12; usage.alignment = .top
        let root = NSView()
        for v in [usage, boardScroll, feedTitle, filter, fs] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            usage.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), usage.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            usage.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            boardScroll.topAnchor.constraint(equalTo: usage.bottomAnchor, constant: 12), boardScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            boardScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), boardScroll.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.58),
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
        v.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        for x in [t, sub, sum] { x.preferredMaxLayoutWidth = 210 }
        return v
    }

    @objc private func openCard(_ b: NSButton) { if let id = b.identifier?.rawValue { Workbench.focus(session: id); NSApp.mainWindow?.makeKeyAndOrderFront(nil) } }

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
    @objc private func openEvent() { if feed.clickedRow >= 0 { Workbench.focus(session: shown[feed.clickedRow].session.id) } }
}
