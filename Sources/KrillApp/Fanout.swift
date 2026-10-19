import AppKit
import Core

/// One prompt → N agents in N worktrees; compare the variants and accept the best.
@MainActor
final class FanoutController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static var open: [FanoutController] = []
    private var window: NSWindow!
    private var ids: [String]
    private var rows: [JSONValue] = []
    private let table = NSTableView()
    private let diff = DiffViewController()
    private let status = NSTextField(labelWithString: "")

    /// Ask for prompt + agents, start the fan-out, then show the compare window.
    static func start(repo: Repo) {
        let a = NSAlert(); a.messageText = "Fan-out"; a.informativeText = "Same prompt to several agents, each in its own worktree."
        let box = NSStackView(); box.orientation = .vertical; box.alignment = .leading
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 90)); text.isRichText = false; text.font = .systemFont(ofSize: 13)
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 90)); sv.documentView = text; sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
        sv.widthAnchor.constraint(equalToConstant: 380).isActive = true; sv.heightAnchor.constraint(equalToConstant: 90).isActive = true
        box.addArrangedSubview(sv)
        var steppers: [(String, NSStepper, NSTextField)] = []
        for ag in AppModel.shared.agents {
            let row = NSStackView(); let label = NSTextField(labelWithString: "0 × \(ag.name)")
            let st = NSStepper(); st.minValue = 0; st.maxValue = 4; st.integerValue = ag.id == AgentCatalog.defaultAgent ? 2 : 0
            label.stringValue = "\(st.integerValue) × \(ag.name)"
            st.target = StepperSink.shared; st.action = #selector(StepperSink.changed(_:)); StepperSink.shared.labels[ObjectIdentifier(st)] = (label, ag.name)
            row.addArrangedSubview(st); row.addArrangedSubview(label); box.addArrangedSubview(row)
            steppers.append((ag.id, st, label))
        }
        box.frame = NSRect(x: 0, y: 0, width: 380, height: 100 + 26 * steppers.count)
        a.accessoryView = box; a.addButton(withTitle: "Start"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = text
        guard runAsSheet(a) == .alertFirstButtonReturn, !text.string.isEmpty else { return }
        let agents = steppers.flatMap { Array(repeating: JSONValue.string($0.0), count: $0.1.integerValue) }
        guard !agents.isEmpty else { return }
        Task {
            guard let r = await AppModel.shared.call("fanout.start", .obj(["repoId": .string(repo.id), "prompt": .string(text.string), "agents": .array(agents)])) else { return }
            await AppModel.shared.refresh()
            show(ids: (r.array ?? []).compactMap { $0["worktree"]?.string }, title: String(text.string.prefix(40)))
        }
    }

    /// Fan-out groups are recognised by branch name: <tag>-<n>-<agent>.
    static func groups() -> [String: [Worktree]] {
        Dictionary(grouping: AppModel.shared.worktrees.filter { $0.branch.hasPrefix("fanout-") && !$0.archived }) { w in
            w.branch.split(separator: "-").prefix(2).joined(separator: "-")
        }
    }

    static func show(ids: [String], title: String) {
        let c = FanoutController(ids: ids, title: title); open.append(c)
    }

    private init(ids: [String], title: String) {
        self.ids = ids
        super.init()
        for (id, t, w) in [("branch", "Variant", 200.0), ("files", "Files", 50), ("add", "+", 50), ("del", "−", 50), ("tests", "Tests", 60), ("status", "Agent", 80)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = t; c.width = w; table.addTableColumn(c)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 22
        let ts = NSScrollView(); ts.documentView = table; ts.hasVerticalScroller = true
        let bar = NSStackView(); bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        for (t, sel) in [("Refresh", #selector(refresh)), ("Run Tests", #selector(runTests)), ("Accept Selected", #selector(accept))] {
            let b = NSButton(title: t, target: self, action: sel); b.bezelStyle = .rounded; bar.addArrangedSubview(b)
        }
        bar.addArrangedSubview(status)
        let body = NSView()
        for v in [ts, diff.view] { v.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(v) }
        NSLayoutConstraint.activate([
            ts.topAnchor.constraint(equalTo: body.topAnchor), ts.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            ts.trailingAnchor.constraint(equalTo: body.trailingAnchor), ts.heightAnchor.constraint(equalToConstant: 160),
            diff.view.topAnchor.constraint(equalTo: ts.bottomAnchor), diff.view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            diff.view.trailingAnchor.constraint(equalTo: body.trailingAnchor), diff.view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Fan-out: \(title)"; window.isReleasedWhenClosed = false
        window.contentView = pinned(bar: bar, body: body); window.center(); window.makeKeyAndOrderFront(nil)
        refresh()
    }

    @objc private func refresh() { Task { await load(test: false) } }
    @objc private func runTests() { status.stringValue = "Running tests…"; Task { await load(test: true); status.stringValue = "Tests done" } }

    private func load(test: Bool) async {
        rows = (await AppModel.shared.call("fanout.compare", .obj(["ids": .array(ids.map { .string($0) }), "test": .bool(test)])))?.array ?? rows
        table.reloadData()
    }

    @objc private func accept() {
        guard table.selectedRow >= 0, let win = rows[table.selectedRow]["id"]?.string else { NSSound.beep(); return }
        let others = ids.filter { $0 != win }
        let a = NSAlert(); a.messageText = "Merge this variant and archive the other \(others.count)?"
        a.informativeText = "Uncommitted changes in the winner must be committed first."
        a.addButton(withTitle: "Accept"); a.addButton(withTitle: "Cancel")
        guard runAsSheet(a) == .alertFirstButtonReturn else { return }
        Task {
            guard let r = await AppModel.shared.call("fanout.accept", .obj(["id": .string(win), "others": .array(others.map { .string($0) })])) else { return }
            if r["merged"]?.bool == true { status.stringValue = "Merged. Others archived."; ids = [win]; await load(test: false) }
            else { status.stringValue = "Conflicts: " + (r["conflicts"]?.array ?? []).compactMap(\.string).joined(separator: ", ") }
        }
    }

    func select(_ r: Int) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.table.selectRowIndexes([r], byExtendingSelection: false) } }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let s: String
        switch col?.identifier.rawValue {
        case "branch": s = r["branch"]?.string ?? ""
        case "files": s = "\(r["files"]?.int ?? 0)"
        case "add": s = "+\(r["additions"]?.int ?? 0)"
        case "del": s = "−\(r["deletions"]?.int ?? 0)"
        case "tests": s = r["tests"]?.bool.map { $0 ? "✅" : "❌" } ?? "—"
        default:
            let id = r["id"]?.string
            s = AppModel.shared.sessions.last { $0.worktreeId == id && $0.agent != "custom" }?.status.rawValue ?? "—"
        }
        return NSTextField(labelWithString: s)
    }
    func tableViewSelectionDidChange(_ n: Notification) {
        guard table.selectedRow >= 0 else { return }
        diff.show(worktree: rows[table.selectedRow]["id"]?.string)
    }
}

@MainActor
final class StepperSink: NSObject {
    static let shared = StepperSink()
    var labels: [ObjectIdentifier: (NSTextField, String)] = [:]
    @objc func changed(_ s: NSStepper) { if let (l, n) = labels[ObjectIdentifier(s)] { l.stringValue = "\(s.integerValue) × \(n)" } }
}
