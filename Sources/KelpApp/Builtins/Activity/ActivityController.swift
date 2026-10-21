import AppKit
import Core

/// What each running session costs, like Activity Monitor for agents: CPU (100% = one core) and memory summed over
/// everything under its terminal, busiest first, with Stop. Measured every two seconds while the panel shows.
@MainActor
final class ActivityController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row { var session: Session; var cpu: Double; var memory: Int; var processes: Int }
    private let table = NSTableView()
    private let total = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: String(localized: "No sessions running."))
    private var rows: [Row] = []
    private var timer: Timer?

    override func loadView() {
        let col = NSTableColumn(identifier: .init("a")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col); table.headerView = nil; table.style = .plain; table.backgroundColor = .clear
        table.rowHeight = TextSize.of(40); table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(open)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        total.font = .uiDigits(11); total.textColor = .secondaryLabelColor
        empty.textColor = .secondaryLabelColor; empty.isHidden = true
        let v = NSView()
        for x in [total, scroll, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            total.topAnchor.constraint(equalTo: v.topAnchor, constant: 10), total.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: total.bottomAnchor, constant: 6), scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.topAnchor.constraint(equalTo: total.bottomAnchor, constant: 40)
        ])
        view = v
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
    }
    override func viewDidDisappear() { super.viewDidDisappear(); timer?.invalidate(); timer = nil }

    private func reload() {
        Task {
            let m = AppModel.shared
            let read = await m.tryCall(SessionUsage())
            let usage = read.value ?? []
            // Couldn't measure: say why where "No sessions running." would be, not that nothing runs.
            empty.stringValue = read.error.map { String(localized: "Couldn't measure the sessions: \($0)") } ?? String(localized: "No sessions running.")
            rows = usage.compactMap { u in
                guard let s = m.session(u.session) else { return nil }
                return Row(session: s, cpu: u.cpu, memory: u.memory, processes: u.processes)
            }
            let cpu = rows.reduce(0) { $0 + $1.cpu }, mem = rows.reduce(0) { $0 + $1.memory }
            total.stringValue = rows.isEmpty ? "" : String(localized: "\(rows.count) sessions · CPU \(Self.percent(cpu)) · \(Self.bytes(mem))")
            empty.isHidden = !rows.isEmpty
            table.reloadData()
        }
    }

    static func percent(_ cpu: Double) -> String { cpu < 10 ? String(format: "%.1f%%", cpu) : "\(Int(cpu.rounded()))%" }
    static func bytes(_ b: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row], s = r.session, m = AppModel.shared
        let icon = NSImageView(image: (s.agent == "shell" ? NSImage.symbol("terminal") : AgentCatalog.icon(s.agent)) ?? NSImage())
        let name = NSTextField(labelWithString: s.agent == "shell" ? (s.title.isEmpty ? String(localized: "Terminal") : s.title) : AgentCatalog.displayName(s))
        name.font = .ui(12, weight: .medium); name.lineBreakMode = .byTruncatingTail
        let place = NSTextField(labelWithString: [m.worktree(s.worktreeId)?.displayName, String(localized: "\(r.processes) processes")]
            .compactMap { $0 }.joined(separator: " · "))
        place.font = .ui(11); place.textColor = .secondaryLabelColor; place.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, place]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
        let cost = NSTextField(labelWithString: "\(Self.percent(r.cpu))\n\(Self.bytes(r.memory))")
        cost.font = .uiDigits(11); cost.alignment = .right; cost.textColor = r.cpu > 80 ? .systemOrange : .secondaryLabelColor
        let stop = ClosureButton(title: "") { AgentActions.stop([s.id]) }
        stop.image = .symbol("stop.circle", String(localized: "Stop")); stop.isBordered = false; stop.contentTintColor = .secondaryLabelColor
        stop.toolTip = String(localized: "Stop \(name.stringValue) (ends its processes)")
        for x in [name, place, text] { x.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let rowView = NSStackView(views: [icon, text, NSView(), cost, stop]); rowView.spacing = 8
        rowView.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return rowView
    }

    @objc private func open() {
        guard rows.indices.contains(table.clickedRow) else { return }
        Workbench.focus(session: rows[table.clickedRow].session.id)
    }
}
