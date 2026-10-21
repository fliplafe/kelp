import AppKit
import SwiftUI
import Core

/// GitHub PRs / issues / Projects and Linear tasks for the selected project, with the actions that close the loop:
/// issue → worktree + agent, failed check / review comments → agent, PR merge, Linear state.
@MainActor
final class TasksViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let source = NSPopUpButton()
    private let split = NSSplitView()
    private var dividerPlaced = false
    private let filter = NSPopUpButton()
    let status = NSTextField(labelWithString: "")
    let table = NSTableView()
    private let detail = NSStackView()
    var rows: [JSONValue] = []
    private var repoId: String?
    private var projectOwner: String?
    private var jiraJQL = "project = ENG AND statusCategory != Done ORDER BY priority DESC"

    override func loadView() {
        source.addItems(withTitles: [String(localized: "Pull Requests"), String(localized: "Issues"),
            String(localized: "Linear"), String(localized: "Jira"), String(localized: "Projects")])
        source.selectItem(at: 0); source.target = self; source.action = #selector(sourceChanged)
        filter.target = self; filter.action = #selector(filterChanged)
        let refresh = NSButton(image: .symbol("arrow.clockwise", String(localized: "Refresh")), target: self, action: #selector(reload))
        refresh.bezelStyle = .texturedRounded
        status.textColor = .secondaryLabelColor; status.font = .ui(11)
        status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 3; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for c in [source, filter] as [NSControl] { c.controlSize = .small; c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        // An inspector panel: controls on one line, the status under them, list above the details.
        let controls = NSStackView(views: [source, filter, refresh]); controls.spacing = 6
        showAll.bezelStyle = .push; showAll.controlSize = .small; showAll.isHidden = true
        let statusRow = NSStackView(views: [status, showAll]); statusRow.spacing = 6
        let bar = NSStackView(views: [controls, statusRow]); bar.orientation = .vertical; bar.alignment = .leading; bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        let col = NSTableColumn(identifier: .init("t")); table.addTableColumn(col); table.headerView = nil
        table.rowHeight = TextSize.of(40); table.dataSource = self; table.delegate = self; table.style = .inset
        let ts = NSScrollView(); ts.documentView = table; ts.hasVerticalScroller = true
        detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 10; detail.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        let ds = NSScrollView(); ds.hasVerticalScroller = true; ds.drawsBackground = false
        let flip = FlippedView(); flip.translatesAutoresizingMaskIntoConstraints = false; ds.documentView = flip
        detail.translatesAutoresizingMaskIntoConstraints = false; flip.addSubview(detail)
        NSLayoutConstraint.activate([detail.topAnchor.constraint(equalTo: flip.topAnchor), detail.leadingAnchor.constraint(equalTo: flip.leadingAnchor),
                                     detail.trailingAnchor.constraint(equalTo: flip.trailingAnchor), detail.bottomAnchor.constraint(equalTo: flip.bottomAnchor),
                                     flip.widthAnchor.constraint(equalTo: ds.contentView.widthAnchor)])
        split.isVertical = false; split.dividerStyle = .thin
        split.addArrangedSubview(ts); split.addArrangedSubview(ds)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        view = pinned(bar: bar, body: split)
        sourceChanged()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Once it has a height: the list gets the larger part, details the rest.
        guard !dividerPlaced, split.bounds.height > 100 else { return }
        dividerPlaced = true; split.setPosition(split.bounds.height * 0.55, ofDividerAt: 0)
    }

    private lazy var showAll = ClosureButton(title: String(localized: "Show All Open")) { [weak self] in self?.filter.selectItem(at: 0); self?.reload() }

    func show(worktree id: String?) {
        let r = AppModel.shared.worktree(id)?.repoId ?? AppModel.shared.repos.first?.id
        guard r != repoId else { return }
        repoId = r
        guard isViewLoaded else { return }
        // Another project: drop its rows now, or Merge on one before the reload would act on a PR number in this repo.
        rows = []; table.reloadData(); showDetail(nil)
        reload(); nameSources()
    }

    /// GitLab calls them merge requests.
    private func nameSources() {
        guard let repoId else { return }
        Task {
            let forge = (try? await AppModel.shared.client?.call("github.forge", .obj(["repoId": .string(repoId)])))?.string
            source.item(at: 0)?.title = forge == "gitlab" ? String(localized: "Merge Requests") : String(localized: "Pull Requests")
        }
    }

    @objc private func sourceChanged() {
        filter.removeAllItems()
        switch source.indexOfSelectedItem {
        case 0: filter.addItems(withTitles: [String(localized: "All open"), String(localized: "Mine"), String(localized: "Review requested")])
        case 1: filter.addItems(withTitles: [String(localized: "All open"), String(localized: "Assigned to me")])
        case 3: filter.addItems(withTitles: [String(localized: "My open issues"), String(localized: "Custom JQL…")])
        case 2:
            filter.addItems(withTitles: [String(localized: "My issues")])
            Task {   // team boards
                for t in (try? await AppModel.shared.client?.call("linear.teams").array) ?? [] {
                    filter.addItem(withTitle: String(localized: "Team: \(t["name"]?.string ?? "")")); filter.lastItem?.representedObject = t["id"]?.string
                }
            }
        default: filter.addItems(withTitles: [String(localized: "Loading projects…")])
        }
        reload()
    }

    /// Custom JQL asks for its query when picked, not on every refresh or workspace switch.
    @objc private func filterChanged() {
        if source.indexOfSelectedItem == 3, filter.indexOfSelectedItem == 1 {
            guard let jql = prompt(String(localized: "Jira search"), "JQL", initial: jiraJQL) else { filter.selectItem(at: 0); reload(); return }
            jiraJQL = jql
        }
        reload()
    }

    @objc private func reload() {
        guard let repoId else { rows = []; table.reloadData(); status.stringValue = String(localized: "Select a project"); return }
        let slow = whileSlow { [weak self] in self?.status.stringValue = String(localized: "Loading…") }
        let src = source.indexOfSelectedItem, f = filter.indexOfSelectedItem
        Task {
            defer { slow.cancel() }
            var rows: [JSONValue] = []
            do {
                let c = AppModel.shared.client
                switch src {
                case 0: rows = try await c?.call("github.prs", .obj(["repoId": .string(repoId), "filter": .string(["open", "mine", "review"][max(0, f)])])).array ?? []
                case 1: rows = try await c?.call("github.issues", .obj(["repoId": .string(repoId), "filter": .string(f == 1 ? "mine" : "open")])).array ?? []
                case 2:
                    let team = filter.selectedItem?.representedObject as? String
                    rows = try await c?.call("linear.issues", team.map { .obj(["teamId": .string($0)]) }).array ?? []
                    if team != nil { rows.sort { ($0["state"]?["name"]?.string ?? "") < ($1["state"]?["name"]?.string ?? "") } }
                case 3:
                    rows = try await c?.call("jira.issues", .object(f == 1 ? ["jql": .string(jiraJQL)] : [:])).array ?? []
                default:
                    if filter.itemTitles.first == String(localized: "Loading projects…") {
                        let ps = try await c?.call("github.projects", .obj(["repoId": .string(repoId)])).array ?? []
                        filter.removeAllItems()
                        for p in ps { filter.addItem(withTitle: p["title"]?.string ?? ""); filter.lastItem?.tag = p["number"]?.int ?? 0 }
                        projectOwner = ps.first?["url"]?.string.flatMap { URL(string: $0)?.pathComponents.dropFirst(2).first }
                    }
                    if let owner = projectOwner, let n = filter.selectedItem?.tag {
                        rows = (try await c?.call("github.projectItems", .obj(["owner": .string(owner), "number": .int(n)])).array ?? [])
                            .sorted { ($0["status"]?.string ?? "~") < ($1["status"]?.string ?? "~") }
                    } else { rows = [] }
                }
                // Switched project or list meanwhile: these rows belong to the old one.
                guard repoId == self.repoId, src == source.indexOfSelectedItem else { return }
                self.rows = rows
                // Empty because of the filter isn't the same as empty: say which, and offer the way back.
                let narrowed = rows.isEmpty && f > 0 && src < 2
                status.stringValue = rows.isEmpty
                    ? (narrowed ? String(localized: "None in “\(filter.titleOfSelectedItem ?? "")”.") : String(localized: "Nothing open here."))
                    : String(localized: "\(rows.count) items")
                showAll.isHidden = !narrowed
            } catch {
                guard repoId == self.repoId, src == source.indexOfSelectedItem else { return }
                showAll.isHidden = true
                self.rows = []; status.stringValue = (error as? RPCError)?.message ?? "\(error)"
                if src == 2 { status.stringValue = String(localized: "Connect Linear in Settings › Integrations") }
                if src == 3 { status.stringValue = String(localized: "Connect Jira in Settings › Integrations") }
                if src == 4 { status.stringValue = String(localized: "Projects need `gh auth refresh -s read:project`") }
            }
            table.reloadData(); showDetail(nil)
        }
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let (title, sub): (String, String) = switch source.indexOfSelectedItem {
        case 0: ("#\(r["number"]?.int ?? 0)  \(r["title"]?.string ?? "")", "\(r["author"]?.string ?? "") · \(r["headRefName"]?.string ?? "")\(Self.checksText(r))")
        case 1: ("#\(r["number"]?.int ?? 0)  \(r["title"]?.string ?? "")", (r["labels"]?.array ?? []).compactMap(\.string).joined(separator: ", "))
        case 2: ("\(r["identifier"]?.string ?? "")  \(r["title"]?.string ?? "")", "\(r["state"]?["name"]?.string ?? "") · \(r["team"]?["name"]?.string ?? "")")
        case 3: ("\(r["key"]?.string ?? "")  \(r["title"]?.string ?? "")", "\(r["status"]?.string ?? "") · \(r["type"]?.string ?? "") · \(r["project"]?.string ?? "")")
        default: (r["title"]?.string ?? "", "\(r["status"]?.string ?? String(localized: "No status")) · \(r["type"]?.string ?? "")")
        }
        let t1 = NSTextField(labelWithString: title); t1.font = .ui(13, weight: .medium); t1.lineBreakMode = .byTruncatingTail
        let t2 = NSTextField(labelWithString: sub); t2.font = .ui(11); t2.textColor = .secondaryLabelColor; t2.lineBreakMode = .byTruncatingTail
        let s = NSStackView(views: [t1, t2]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 2
        return s
    }
    static func checksText(_ r: JSONValue) -> String {
        let c = r["checks"]; let f = c?["failed"]?.int ?? 0, p = c?["pending"]?.int ?? 0, ok = c?["passed"]?.int ?? 0
        if f > 0 { return String(localized: " · ✕ \(f) failing") }
        if p > 0 { return String(localized: " · ◌ \(p) pending") }
        return ok > 0 ? String(localized: " · ✓ checks passed") : ""
    }
    func tableViewSelectionDidChange(_ n: Notification) { showDetail(table.selectedRow >= 0 ? rows[table.selectedRow] : nil) }

    // MARK: detail
    private func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s); l.font = .ui(size, weight: weight); l.textColor = color; l.isSelectable = true
        l.preferredMaxLayoutWidth = 520; return l
    }
    private func button(_ t: String, _ sym: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: t, action: action); b.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil); b.imagePosition = .imageLeading
        b.bezelStyle = .rounded; return b
    }

    private func showDetail(_ r: JSONValue?) {
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let r else {
            detail.addArrangedSubview(label(rows.isEmpty ? "" : String(localized: "Select an item"), color: .secondaryLabelColor)); return
        }
        let url = r["url"]?.string
        switch source.indexOfSelectedItem {
        case 0: prDetail(r)
        case 3:
            let key = r["key"]?.string ?? ""
            detail.addArrangedSubview(label("\(key)  \(r["title"]?.string ?? "")", size: 17, weight: .semibold))
            detail.addArrangedSubview(jiraTransitions(key, current: r["status"]?.string ?? ""))
            detail.addArrangedSubview(button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in self?.startTask(r, linear: false, jira: true) })
            let body = r["description"]?.string ?? ""
            detail.addArrangedSubview(label(body.isEmpty ? String(localized: "No description.") : String(body.prefix(6000)),
                color: body.isEmpty ? .secondaryLabelColor : .labelColor))
        case 1, 2:
            let linear = source.indexOfSelectedItem == 2
            let ref = linear ? (r["identifier"]?.string ?? "") : "#\(r["number"]?.int ?? 0)"
            detail.addArrangedSubview(label("\(ref)  \(r["title"]?.string ?? "")", size: 17, weight: .semibold))
            if linear { detail.addArrangedSubview(statePicker(r)) }
            detail.addArrangedSubview(button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in self?.startTask(r, linear: linear) })
            let body = (linear ? r["description"]?.string : r["body"]?.string) ?? ""
            detail.addArrangedSubview(label(body.isEmpty ? String(localized: "No description.") : String(body.prefix(6000)),
                color: body.isEmpty ? .secondaryLabelColor : .labelColor))
        default:
            detail.addArrangedSubview(label(r["title"]?.string ?? "", size: 17, weight: .semibold))
            detail.addArrangedSubview(label(String(localized: "Status: \(r["status"]?.string ?? "—")"), color: .secondaryLabelColor))
        }
        if let url, let u = URL(string: url) { detail.addArrangedSubview(button(String(localized: "Open on the Web"), "safari") { NSWorkspace.shared.open(u) }) }
    }

    private func worktreeFor(branch: String) -> Worktree? { AppModel.shared.worktrees.first { $0.branch == branch && !$0.archived } }

    private func prDetail(_ r: JSONValue) {
        let n = r["number"]?.int ?? 0, branch = r["headRefName"]?.string ?? ""
        detail.addArrangedSubview(label("#\(n)  \(r["title"]?.string ?? "")", size: 17, weight: .semibold))
        let author = r["author"]?.string ?? "", draft = r["isDraft"]?.bool == true ? String(localized: " · draft") : ""
        let decision = r["reviewDecision"]?.string.map { " · " + $0.lowercased().replacingOccurrences(of: "_", with: " ") } ?? ""
        detail.addArrangedSubview(label(String(localized: "\(author) wants to merge \(branch)\(draft)\(decision)"), color: .secondaryLabelColor))
        let wt = worktreeFor(branch: branch)
        let actions = NSStackView(); actions.spacing = 8
        if let wt {
            actions.addArrangedSubview(button(String(localized: "Open Worktree"), "arrow.triangle.branch") { Workbench.show(workspace: wt.id) })
            actions.addArrangedSubview(button(String(localized: "Send Review Comments to Agent"), "text.bubble") { [weak self] in self?.sendReview(n, wt) })
        }
        actions.addArrangedSubview(button(String(localized: "Merge (squash)"), "arrow.triangle.merge") { [weak self] in self?.merge(n, wt) })
        detail.addArrangedSubview(actions)
        let checksBox = NSStackView(); checksBox.orientation = .vertical; checksBox.alignment = .leading; checksBox.spacing = 4
        detail.addArrangedSubview(label(String(localized: "Checks"), weight: .semibold)); detail.addArrangedSubview(checksBox)
        guard let repoId else { return }
        Task {
            let checks = (try? await AppModel.shared.client?.call("github.checks", .obj(["repoId": .string(repoId), "pr": .int(n)])).array) ?? []
            if checks.isEmpty { checksBox.addArrangedSubview(label(String(localized: "No checks reported."), color: .secondaryLabelColor)) }
            for c in checks {
                let bucket = c["bucket"]?.string ?? ""
                let icon = bucket == "pass" ? "✓" : bucket == "fail" ? "✕" : bucket == "pending" ? "◌" : "–"
                let row = NSStackView(views: [label("\(icon)  \(c["name"]?.string ?? "")", color: bucket == "fail" ? .systemRed : .labelColor)]); row.spacing = 8
                if bucket == "fail", let run = c["runId"]?.int, let wt {
                    row.addArrangedSubview(button(String(localized: "Fix with Agent"), "wrench.and.screwdriver") { [weak self] in
                        self?.fixCheck(c["name"]?.string ?? "", run, wt)
                    })
                }
                checksBox.addArrangedSubview(row)
            }
        }
    }

    private func statePicker(_ r: JSONValue) -> NSView {
        let pop = NSPopUpButton(); pop.addItem(withTitle: r["state"]?["name"]?.string ?? String(localized: "State"))
        Task {
            guard let team = r["team"]?["id"]?.string, let states = try? await AppModel.shared.client?.call("linear.states", .obj(["teamId": .string(team)])).array else { return }
            pop.removeAllItems()
            for s in states { pop.addItem(withTitle: s["name"]?.string ?? ""); pop.lastItem?.representedObject = s["id"]?.string }
            pop.selectItem(withTitle: r["state"]?["name"]?.string ?? "")
        }
        let id = r["id"]?.string ?? ""
        let sink = ClosureTarget { [weak pop] in
            guard let sid = pop?.selectedItem?.representedObject as? String else { return }
            Task { await AppModel.shared.call("linear.setState", .obj(["issueId": .string(id), "stateId": .string(sid)])) }
        }
        pop.target = sink; pop.action = #selector(ClosureTarget.fire); objc_setAssociatedObject(pop, "sink", sink, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "State:")), pop]); row.spacing = 6
        return row
    }

    private func jiraTransitions(_ key: String, current: String) -> NSView {
        let pop = NSPopUpButton(); pop.addItem(withTitle: current.isEmpty ? String(localized: "Status") : current)
        Task {
            let ts = (try? await AppModel.shared.client?.call("jira.transitions", .obj(["key": .string(key)])).array) ?? []
            for t in ts { pop.addItem(withTitle: "→ " + (t["name"]?.string ?? "")); pop.lastItem?.representedObject = t["id"]?.string }
        }
        let sink = ClosureTarget { [weak pop, weak self] in
            guard let id = pop?.selectedItem?.representedObject as? String else { return }
            Task {
                if await AppModel.shared.call("jira.transition", .obj(["key": .string(key), "id": .string(id)])) != nil {
                    self?.status.stringValue = String(localized: "Moved \(key)")
                }
            }
        }
        pop.target = sink; pop.action = #selector(ClosureTarget.fire); objc_setAssociatedObject(pop, "sink", sink, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "Status:")), pop]); row.spacing = 6
        return row
    }

    /// The default agent starts on the issue in the workspace on screen, its text typed in but not sent: whoever filed the
    /// issue wrote it, so the user reads it before the agent acts on it.
    private func startTask(_ r: JSONValue, linear: Bool, jira: Bool = false) {
        let ref = jira ? (r["key"]?.string ?? "") : linear ? (r["identifier"]?.string ?? "") : "#\(r["number"]?.int ?? 0)"
        let body = ((linear || jira) ? r["description"] : r["body"])?.string ?? ""
        let brief = ["Work on \(ref): \(r["title"]?.string ?? "")", body, r["url"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard let editor = Workbench.editor else { NSSound.beep(); return }
        editor.newAgent(nil, prompt: brief, extra: ["draft": true])
    }

    private func agentSession(_ wt: Worktree) -> String? {
        AppModel.shared.sessions.last { $0.worktreeId == wt.id && $0.status != .exited && $0.agent != "shell" && $0.agent != "custom" }?.id
    }
    private func sendRecipe(_ name: String, _ wt: Worktree, _ vars: [String: String]) async {
        guard let sid = agentSession(wt) else { status.stringValue = String(localized: "No running agent in \(wt.branch) — start one first"); return }
        guard await GitFix.type(name, worktree: wt.id, vars: vars, into: sid) else { return }
        status.stringValue = String(localized: "Typed into \(AppModel.shared.session(sid)?.displayTitle ?? "agent") — press Return there to send")
    }
    private func fixCheck(_ name: String, _ run: Int, _ wt: Worktree) {
        guard let repoId else { return }
        Task {
            let log = (await AppModel.shared.call("github.failedLog", .obj(["repoId": .string(repoId), "runId": .int(run)])))?.string ?? ""
            await sendRecipe("fixCI", wt, ["check": name, "error": log])
        }
    }
    private func sendReview(_ n: Int, _ wt: Worktree) {
        guard let repoId else { return }
        Task {
            let cs = (try? await AppModel.shared.client?.call("github.reviewComments", .obj(["repoId": .string(repoId), "pr": .int(n)])).array) ?? []
            guard !cs.isEmpty else { status.stringValue = String(localized: "No review comments"); return }
            var parts: [String] = []
            for (i, c) in cs.enumerated() {
                let line: String = c["line"]?.int.map { ":\($0)" } ?? ""
                let loc: String = c["path"]?.string.map { $0 + line } ?? String(localized: "General")
                parts.append("\(i + 1). \(loc) (\(c["author"]?.string ?? "")):\n   \(c["body"]?.string ?? "")")
            }
            let text = parts.joined(separator: "\n\n")
            await sendRecipe("review", wt, ["comments": text])
        }
    }
    private func merge(_ n: Int, _ wt: Worktree?) {
        let a = NSAlert()
        a.messageText = String(localized: "Squash and merge #\(n)?"); a.addButton(withTitle: String(localized: "Merge")); a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            var p: [String: JSONValue] = ["pr": .int(n)]
            if let wt { p["worktreeId"] = .string(wt.id) } else if let w = AppModel.shared.worktrees.first(where: { $0.repoId == repoId }) { p["worktreeId"] = .string(w.id) }
            if await AppModel.shared.call("github.pr-merge", .object(p)) != nil { status.stringValue = String(localized: "Merged #\(n)"); reload() }
        }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class ClosureButton: NSButton {
    private var handler: (() -> Void)?
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero); self.title = title; handler = action; target = self; self.action = #selector(fire)
    }
    @objc private func fire() { handler?() }
}

final class ClosureTarget: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}
