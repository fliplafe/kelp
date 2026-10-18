import AppKit
import SwiftUI
import Core

/// GitHub PRs / issues / Projects and Linear tasks for the selected project, with the actions that close the loop:
/// issue → worktree + agent, failed check / review comments → agent, PR merge, Linear state.
@MainActor
final class TasksViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let source = NSSegmentedControl(labels: ["Pull Requests", "Issues", "Linear", "Jira", "Projects"], trackingMode: .selectOne, target: nil, action: nil)
    private let filter = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let detail = NSStackView()
    private var rows: [JSONValue] = []
    private var repoId: String?
    private var worktreeId: String?
    private var projectOwner: String?
    private var jiraJQL = "project = ENG AND statusCategory != Done ORDER BY priority DESC"

    override func loadView() {
        source.selectedSegment = 0; source.target = self; source.action = #selector(sourceChanged)
        filter.target = self; filter.action = #selector(reload)
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!, target: self, action: #selector(reload))
        refresh.bezelStyle = .texturedRounded
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11); status.lineBreakMode = .byTruncatingTail
        let bar = NSStackView(views: [source, filter, refresh, status]); bar.spacing = 8; bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        let col = NSTableColumn(identifier: .init("t")); table.addTableColumn(col); table.headerView = nil
        table.rowHeight = 40; table.dataSource = self; table.delegate = self; table.style = .inset
        let ts = NSScrollView(); ts.documentView = table; ts.hasVerticalScroller = true
        detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 10; detail.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        let ds = NSScrollView(); ds.hasVerticalScroller = true; ds.drawsBackground = false
        let flip = FlippedView(); flip.translatesAutoresizingMaskIntoConstraints = false; ds.documentView = flip
        detail.translatesAutoresizingMaskIntoConstraints = false; flip.addSubview(detail)
        NSLayoutConstraint.activate([detail.topAnchor.constraint(equalTo: flip.topAnchor), detail.leadingAnchor.constraint(equalTo: flip.leadingAnchor),
                                     detail.trailingAnchor.constraint(equalTo: flip.trailingAnchor), detail.bottomAnchor.constraint(equalTo: flip.bottomAnchor),
                                     flip.widthAnchor.constraint(equalTo: ds.contentView.widthAnchor)])
        let split = NSView()
        for v in [ts, ds] { v.translatesAutoresizingMaskIntoConstraints = false; split.addSubview(v) }
        NSLayoutConstraint.activate([
            ts.topAnchor.constraint(equalTo: split.topAnchor), ts.bottomAnchor.constraint(equalTo: split.bottomAnchor), ts.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            ts.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.42),
            ds.topAnchor.constraint(equalTo: split.topAnchor), ds.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            ds.leadingAnchor.constraint(equalTo: ts.trailingAnchor), ds.trailingAnchor.constraint(equalTo: split.trailingAnchor),
        ])
        view = pinned(bar: bar, body: split)
        sourceChanged()
    }

    func show(worktree id: String?) {
        worktreeId = id
        let r = AppModel.shared.worktree(id)?.repoId ?? AppModel.shared.repos.first?.id
        if r != repoId { repoId = r; if isViewLoaded { reload() } }
    }

    @objc private func sourceChanged() {
        filter.removeAllItems()
        switch source.selectedSegment {
        case 0: filter.addItems(withTitles: ["Open", "Mine", "Review requested"])
        case 1: filter.addItems(withTitles: ["Open", "Assigned to me"])
        case 3: filter.addItems(withTitles: ["My open issues", "Custom JQL…"])
        case 2:
            filter.addItems(withTitles: ["My issues"])
            Task {   // team boards
                for t in (try? await AppModel.shared.client?.call("linear.teams").array) ?? [] {
                    filter.addItem(withTitle: "Team: \(t["name"]?.string ?? "")"); filter.lastItem?.representedObject = t["id"]?.string
                }
            }
        default: filter.addItems(withTitles: ["Loading projects…"])
        }
        reload()
    }

    @objc private func reload() {
        guard let repoId else { rows = []; table.reloadData(); status.stringValue = "Select a project"; return }
        status.stringValue = "Loading…"
        let src = source.selectedSegment, f = filter.indexOfSelectedItem
        Task {
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
                    var p: [String: JSONValue] = [:]
                    if f == 1, let jql = prompt("Jira search", "JQL", initial: jiraJQL) { jiraJQL = jql; p["jql"] = .string(jql) }
                    rows = try await c?.call("jira.issues", .object(p)).array ?? []
                default:
                    if filter.itemTitles.first == "Loading projects…" {
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
                status.stringValue = "\(rows.count) items"
            } catch {
                rows = []; status.stringValue = (error as? RPCError)?.message ?? "\(error)"
                if src == 2 { status.stringValue = "Connect Linear in Settings › Integrations" }
                if src == 3 { status.stringValue = "Connect Jira in Settings › Integrations" }
                if src == 4 { status.stringValue = "Projects need `gh auth refresh -s read:project`" }
            }
            table.reloadData(); showDetail(nil)
        }
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let (title, sub): (String, String) = switch source.selectedSegment {
        case 0: ("#\(r["number"]?.int ?? 0)  \(r["title"]?.string ?? "")", "\(r["author"]?.string ?? "") · \(r["headRefName"]?.string ?? "")\(Self.checksText(r))")
        case 1: ("#\(r["number"]?.int ?? 0)  \(r["title"]?.string ?? "")", (r["labels"]?.array ?? []).compactMap(\.string).joined(separator: ", "))
        case 2: ("\(r["identifier"]?.string ?? "")  \(r["title"]?.string ?? "")", "\(r["state"]?["name"]?.string ?? "") · \(r["team"]?["name"]?.string ?? "")")
        case 3: ("\(r["key"]?.string ?? "")  \(r["title"]?.string ?? "")", "\(r["status"]?.string ?? "") · \(r["type"]?.string ?? "") · \(r["project"]?.string ?? "")")
        default: (r["title"]?.string ?? "", "\(r["status"]?.string ?? "No status") · \(r["type"]?.string ?? "")")
        }
        let t1 = NSTextField(labelWithString: title); t1.font = .systemFont(ofSize: 13, weight: .medium); t1.lineBreakMode = .byTruncatingTail
        let t2 = NSTextField(labelWithString: sub); t2.font = .systemFont(ofSize: 11); t2.textColor = .secondaryLabelColor; t2.lineBreakMode = .byTruncatingTail
        let s = NSStackView(views: [t1, t2]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 2
        return s
    }
    static func checksText(_ r: JSONValue) -> String {
        let c = r["checks"]; let f = c?["failed"]?.int ?? 0, p = c?["pending"]?.int ?? 0, ok = c?["passed"]?.int ?? 0
        if f > 0 { return " · ✕ \(f) failing" }; if p > 0 { return " · ◌ \(p) pending" }; return ok > 0 ? " · ✓ checks passed" : ""
    }
    func tableViewSelectionDidChange(_ n: Notification) { showDetail(table.selectedRow >= 0 ? rows[table.selectedRow] : nil) }

    // MARK: detail
    private func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s); l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color; l.isSelectable = true
        l.preferredMaxLayoutWidth = 520; return l
    }
    private func button(_ t: String, _ sym: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: t, action: action); b.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil); b.imagePosition = .imageLeading
        b.bezelStyle = .rounded; return b
    }

    private func showDetail(_ r: JSONValue?) {
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let r else {
            detail.addArrangedSubview(label(rows.isEmpty ? "" : "Select an item", color: .secondaryLabelColor)); return
        }
        let url = r["url"]?.string
        switch source.selectedSegment {
        case 0: prDetail(r)
        case 3:
            let key = r["key"]?.string ?? ""
            detail.addArrangedSubview(label("\(key)  \(r["title"]?.string ?? "")", size: 17, weight: .semibold))
            detail.addArrangedSubview(jiraTransitions(key, current: r["status"]?.string ?? ""))
            detail.addArrangedSubview(button("Start Task in New Worktree", "arrow.triangle.branch") { [weak self] in self?.startTask(r, linear: false, jira: true) })
            let body = r["description"]?.string ?? ""
            detail.addArrangedSubview(label(body.isEmpty ? "No description." : String(body.prefix(6000)), color: body.isEmpty ? .secondaryLabelColor : .labelColor))
        case 1, 2:
            let linear = source.selectedSegment == 2
            let ref = linear ? (r["identifier"]?.string ?? "") : "#\(r["number"]?.int ?? 0)"
            detail.addArrangedSubview(label("\(ref)  \(r["title"]?.string ?? "")", size: 17, weight: .semibold))
            if linear { detail.addArrangedSubview(statePicker(r)) }
            detail.addArrangedSubview(button("Start Task in New Worktree", "arrow.triangle.branch") { [weak self] in self?.startTask(r, linear: linear) })
            let body = (linear ? r["description"]?.string : r["body"]?.string) ?? ""
            detail.addArrangedSubview(label(body.isEmpty ? "No description." : String(body.prefix(6000)), color: body.isEmpty ? .secondaryLabelColor : .labelColor))
        default:
            detail.addArrangedSubview(label(r["title"]?.string ?? "", size: 17, weight: .semibold))
            detail.addArrangedSubview(label("Status: \(r["status"]?.string ?? "—")", color: .secondaryLabelColor))
        }
        if let url, let u = URL(string: url) { detail.addArrangedSubview(button("Open on the Web", "safari") { NSWorkspace.shared.open(u) }) }
    }

    private func worktreeFor(branch: String) -> Worktree? { AppModel.shared.worktrees.first { $0.branch == branch && !$0.archived } }

    private func prDetail(_ r: JSONValue) {
        let n = r["number"]?.int ?? 0, branch = r["headRefName"]?.string ?? ""
        detail.addArrangedSubview(label("#\(n)  \(r["title"]?.string ?? "")", size: 17, weight: .semibold))
        detail.addArrangedSubview(label("\(r["author"]?.string ?? "") wants to merge \(branch)\(r["isDraft"]?.bool == true ? " · draft" : "")\(r["reviewDecision"]?.string.map { " · " + $0.lowercased().replacingOccurrences(of: "_", with: " ") } ?? "")", color: .secondaryLabelColor))
        let wt = worktreeFor(branch: branch)
        let actions = NSStackView(); actions.spacing = 8
        if let wt {
            actions.addArrangedSubview(button("Open Worktree", "arrow.triangle.branch") { Workbench.show(workspace: wt.id) })
            actions.addArrangedSubview(button("Send Review Comments to Agent", "text.bubble") { [weak self] in self?.sendReview(n, wt) })
        }
        actions.addArrangedSubview(button("Merge (squash)", "arrow.triangle.merge") { [weak self] in self?.merge(n, wt) })
        detail.addArrangedSubview(actions)
        let checksBox = NSStackView(); checksBox.orientation = .vertical; checksBox.alignment = .leading; checksBox.spacing = 4
        detail.addArrangedSubview(label("Checks", weight: .semibold)); detail.addArrangedSubview(checksBox)
        guard let repoId else { return }
        Task {
            let checks = (try? await AppModel.shared.client?.call("github.checks", .obj(["repoId": .string(repoId), "pr": .int(n)])).array) ?? []
            if checks.isEmpty { checksBox.addArrangedSubview(label("No checks reported.", color: .secondaryLabelColor)) }
            for c in checks {
                let bucket = c["bucket"]?.string ?? ""
                let icon = bucket == "pass" ? "✓" : bucket == "fail" ? "✕" : bucket == "pending" ? "◌" : "–"
                let row = NSStackView(views: [label("\(icon)  \(c["name"]?.string ?? "")", color: bucket == "fail" ? .systemRed : .labelColor)]); row.spacing = 8
                if bucket == "fail", let run = c["runId"]?.int, let wt {
                    row.addArrangedSubview(button("Fix with Agent", "wrench.and.screwdriver") { [weak self] in self?.fixCheck(c["name"]?.string ?? "", run, wt) })
                }
                checksBox.addArrangedSubview(row)
            }
        }
    }

    private func statePicker(_ r: JSONValue) -> NSView {
        let pop = NSPopUpButton(); pop.addItem(withTitle: r["state"]?["name"]?.string ?? "State")
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
        let row = NSStackView(views: [NSTextField(labelWithString: "State:"), pop]); row.spacing = 6
        return row
    }

    private func jiraTransitions(_ key: String, current: String) -> NSView {
        let pop = NSPopUpButton(); pop.addItem(withTitle: current.isEmpty ? "Status" : current)
        Task {
            let ts = (try? await AppModel.shared.client?.call("jira.transitions", .obj(["key": .string(key)])).array) ?? []
            for t in ts { pop.addItem(withTitle: "→ " + (t["name"]?.string ?? "")); pop.lastItem?.representedObject = t["id"]?.string }
        }
        let sink = ClosureTarget { [weak pop, weak self] in
            guard let id = pop?.selectedItem?.representedObject as? String else { return }
            Task { if await AppModel.shared.call("jira.transition", .obj(["key": .string(key), "id": .string(id)])) != nil { self?.status.stringValue = "Moved \(key)" } }
        }
        pop.target = sink; pop.action = #selector(ClosureTarget.fire); objc_setAssociatedObject(pop, "sink", sink, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [NSTextField(labelWithString: "Status:"), pop]); row.spacing = 6
        return row
    }

    private func startTask(_ r: JSONValue, linear: Bool, jira: Bool = false) {
        guard let repoId else { return }
        let form = LaunchForm(withPrompt: true, promptPlaceholder: "Optional extra instructions. The task description is sent automatically.")
        let a = NSAlert(); a.messageText = "Start Task"; a.informativeText = "Creates a branch named after the task, a worktree, and an agent briefed with the description."
        a.accessoryView = form.view; a.addButton(withTitle: "Start"); a.addButton(withTitle: "Cancel")
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            var p = form.params; p["repoId"] = .string(repoId)
            p["ref"] = .string(jira ? (r["key"]?.string ?? "") : linear ? (r["identifier"]?.string ?? "") : "#\(r["number"]?.int ?? 0)")
            p["title"] = r["title"] ?? ""; p["body"] = ((linear || jira) ? r["description"] : r["body"]) ?? ""; p["url"] = r["url"] ?? ""
            if linear { p["linearId"] = r["id"] ?? ""; if let b = r["branchName"]?.string { p["branch"] = .string(b) } }
            if let pre = UserDefaults.standard.string(forKey: "branchPrefix") { p["branchPrefix"] = .string(pre) }
            let extra = form.prompt.string.trimmingCharacters(in: .whitespacesAndNewlines); if !extra.isEmpty { p["prompt"] = .string(extra) }
            guard let res = await AppModel.shared.call("task.fromIssue", .object(p)), let wid = res["worktree"]?["id"]?.string,
                  let s = try? res["session"]?.decode(Session.self) else { return }
            await AppModel.shared.refresh()
            AppModel.shared.upsert(s); Workbench.show(workspace: wid); Workbench.open(TabURI.session(s.id))
        }
    }

    private func agentSession(_ wt: Worktree) -> String? {
        AppModel.shared.sessions.last { $0.worktreeId == wt.id && $0.status != .exited && $0.agent != "shell" && $0.agent != "custom" }?.id
    }
    private func sendRecipe(_ name: String, _ wt: Worktree, _ vars: [String: String]) async {
        guard let sid = agentSession(wt) else { status.stringValue = "No running agent in \(wt.branch) — start one first"; return }
        var v: [String: JSONValue] = [:]; for (k, x) in vars { v[k] = .string(x) }
        guard let text = await AppModel.shared.call("recipe.render", .obj(["id": .string(wt.id), "name": .string(name), "vars": .object(v)]))?.string else { return }
        await AppModel.shared.call("session.send", .obj(["id": .string(sid), "text": .string(text)]))
        status.stringValue = "Sent to \(AppModel.shared.session(sid)?.displayTitle ?? "agent")"
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
            guard !cs.isEmpty else { status.stringValue = "No review comments"; return }
            var parts: [String] = []
            for (i, c) in cs.enumerated() {
                let line: String = c["line"]?.int.map { ":\($0)" } ?? ""
                let loc: String = c["path"]?.string.map { $0 + line } ?? "General"
                parts.append("\(i + 1). \(loc) (\(c["author"]?.string ?? "")):\n   \(c["body"]?.string ?? "")")
            }
            let text = parts.joined(separator: "\n\n")
            await sendRecipe("review", wt, ["comments": text])
        }
    }
    private func merge(_ n: Int, _ wt: Worktree?) {
        let a = NSAlert(); a.messageText = "Squash and merge #\(n)?"; a.addButton(withTitle: "Merge"); a.addButton(withTitle: "Cancel")
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            var p: [String: JSONValue] = ["pr": .int(n)]
            if let wt { p["worktreeId"] = .string(wt.id) } else if let w = AppModel.shared.worktrees.first(where: { $0.repoId == repoId }) { p["worktreeId"] = .string(w.id) }
            if await AppModel.shared.call("github.pr-merge", .object(p)) != nil { status.stringValue = "Merged #\(n)"; reload() }
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

struct IntegrationsSettings: View {
    @State private var key = ""
    @State private var linearStatus = "Checking…"
    @State private var ghStatus = "Checking…"
    @State private var jiraStatus = "Checking…"
    @State private var jiraSite = ""
    @State private var jiraEmail = ""
    @State private var jiraToken = ""
    @State private var bbStatus = ""
    @State private var bbUser = ""
    @State private var bbToken = ""
    var body: some View {
        Form {
            Section("GitHub") {
                Text(ghStatus).foregroundStyle(.secondary)
                Text("Krill uses the GitHub CLI and its login (`gh auth login`). Project boards need `gh auth refresh -s read:project`.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Jira") {
                Text(jiraStatus).foregroundStyle(.secondary)
                TextField("Site", text: $jiraSite, prompt: Text("acme.atlassian.net"))
                TextField("Email", text: $jiraEmail)
                SecureField("API token", text: $jiraToken)
                HStack {
                    Button("Connect") { Task {
                        if let r = await AppModel.shared.call("jira.setCredentials", .obj(["site": .string(jiraSite), "email": .string(jiraEmail), "token": .string(jiraToken)])) {
                            jiraStatus = "Connected as \(r["name"]?.string ?? "")"; jiraToken = ""
                        }
                    } }.disabled(jiraSite.isEmpty || jiraEmail.isEmpty || jiraToken.isEmpty)
                    Button("Disconnect") { Task { await AppModel.shared.call("jira.setCredentials", .obj(["site": "", "email": "", "token": ""])); jiraStatus = "Not connected" } }
                }
                Text("API token from id.atlassian.com › Security. Stored in your login keychain.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Bitbucket") {
                Text(bbStatus).foregroundStyle(.secondary)
                TextField("Username or email", text: $bbUser)
                SecureField("API token / app password", text: $bbToken)
                Button("Save") { Task { await AppModel.shared.call("bitbucket.setCredentials", .obj(["user": .string(bbUser), "token": .string(bbToken)])); bbStatus = "Saved"; bbToken = "" } }
                    .disabled(bbUser.isEmpty || bbToken.isEmpty)
                Text("Used for pull requests in repos whose origin is on bitbucket.org.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Linear") {
                Text(linearStatus).foregroundStyle(.secondary)
                SecureField("Personal API key", text: $key)
                HStack {
                    Button("Connect") { Task { await connect() } }.disabled(key.isEmpty)
                    Button("Disconnect") { Task { await AppModel.shared.call("linear.setKey", .obj(["key": ""])); linearStatus = "Not connected" } }
                }
                Text("Create a key in Linear › Settings › Security & access. It's stored in your login keychain.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            let s = await AppModel.shared.call("linear.status")
            linearStatus = s?["connected"]?.bool == true ? "Connected as \(s?["name"]?.string ?? "")" : "Not connected"
            let j = await AppModel.shared.call("jira.status")
            jiraStatus = j?["connected"]?.bool == true ? "Connected to \(j?["site"]?.string ?? "") as \(j?["name"]?.string ?? "")" : "Not connected"
            bbStatus = (await AppModel.shared.call("bitbucket.status"))?["connected"]?.bool == true ? "Credentials saved" : "Not connected"
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", "gh auth status 2>&1 | head -3"]
            let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
            ghStatus = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if ghStatus.isEmpty { ghStatus = "GitHub CLI not found — install it with `brew install gh`." }
        }
    }
    private func connect() async {
        if let me = await AppModel.shared.call("linear.setKey", .obj(["key": .string(key)])) { linearStatus = "Connected as \(me["name"]?.string ?? "")"; key = "" }
    }
}
