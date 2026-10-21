import AppKit
import Core

/// What the daemon's ci.* methods return (Integrations.CI's shapes; the app only reads them).
enum CIRuns {
    /// Finished without success (failed, timed out, cancelled…).
    static func failed(_ status: String, _ conclusion: String?) -> Bool { status == "completed" && !["success", "skipped", "neutral", nil].contains(conclusion) }
    struct Step: Codable {
        var name: String; var status: String; var conclusion: String?
        var failed: Bool { CIRuns.failed(status, conclusion) }
    }
    struct Job: Codable {
        var id: Int, name: String, status: String, conclusion: String?, url: String?
        var steps: [Step]
        var failed: Bool { CIRuns.failed(status, conclusion) }
    }
    struct Run: Codable {
        var id: Int, title: String, workflow: String, status: String, conclusion: String?, event: String, url: String, createdAt: String
        var failed: Bool { CIRuns.failed(status, conclusion) }
    }
    /// The newest run of each workflow (runs come newest first): what the branch's CI says now.
    static func latest(_ runs: [Run]) -> [Run] {
        var seen = Set<String>()
        return runs.filter { seen.insert($0.workflow).inserted }
    }
    struct Workflow: Codable {
        struct Input: Codable { var name: String, description: String, defaultValue: String, options: [String], required: Bool }
        var file: String, name: String, inputs: [Input]
    }
}

/// CI of the branch on screen: runs → jobs → steps, the failed job's log under them (the latest failure opens by itself),
/// Re-run Failed, Ask Agent to Fix, and Run Workflow… for workflows started by hand. GitHub Actions (gh) or GitLab (glab).
@MainActor
final class CIRunsController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Item: NSObject {
        enum Kind { case run(CIRuns.Run), job(CIRuns.Job, run: Int), step(CIRuns.Step) }
        let kind: Kind
        var children: [Item]?
        init(_ k: Kind) { kind = k }
        var id: Int? {
            switch kind {
            case .run(let r): r.id
            case .job(let j, _): j.id
            case .step: nil
            }
        }
    }
    private let outline = NSOutlineView()
    private let branch = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let log = NSTextView()
    private let logBar = NSStackView()
    private let workflowsButton = NSButton()
    private var runs: [Item] = []
    private var workflows: [CIRuns.Workflow] = []
    private var worktree: String?
    private var shownLog = "", shownJob: (job: CIRuns.Job, run: Int)?
    private var branchName = ""
    private var poll: Task<Void, Never>?
    private var autoOpened = Set<Int>()

    override func loadView() {
        branch.font = .ui(12, weight: .semibold); branch.lineBreakMode = .byTruncatingMiddle
        let refresh = button("arrow.clockwise", String(localized: "Refresh")) { [weak self] in self?.reload() }
        workflowsButton.image = .symbol("play.circle", String(localized: "Run Workflow…")); workflowsButton.isBordered = false
        workflowsButton.toolTip = String(localized: "Run Workflow…")
        workflowsButton.contentTintColor = .secondaryLabelColor; workflowsButton.target = self; workflowsButton.action = #selector(runWorkflow)
        workflowsButton.isHidden = true
        let header = NSStackView(views: [NSImageView(image: .symbol("arrow.triangle.branch")), branch, NSView(), workflowsButton, refresh])
        header.spacing = 6; header.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)

        let col = NSTableColumn(identifier: .init("ci")); col.resizingMask = .autoresizingMask
        outline.addTableColumn(col); outline.outlineTableColumn = col; outline.headerView = nil; outline.style = .sourceList
        outline.rowSizeStyle = .custom; outline.dataSource = self; outline.delegate = self
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        note.textColor = .secondaryLabelColor; note.alignment = .center; note.isHidden = true

        log.isEditable = false; log.font = .monospacedSystemFont(ofSize: 10, weight: .regular); log.textContainerInset = NSSize(width: 6, height: 6)
        log.isVerticallyResizable = true; log.autoresizingMask = .width; log.drawsBackground = false
        let logScroll = NSScrollView(); logScroll.documentView = log; logScroll.hasVerticalScroller = true; logScroll.drawsBackground = false
        let copy = textButton(String(localized: "Copy Log")) { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(shownLog, forType: .string); Banner.show(String(localized: "Log copied"))
        }
        let fix = textButton(String(localized: "Ask Agent to Fix")) { [weak self] in self?.askAgent() }
        let rerun = textButton(String(localized: "Re-run Failed")) { [weak self] in self?.rerun() }
        let web = textButton(String(localized: "Open in Browser")) { [weak self] in if let u = self?.shownJob?.job.url { Workbench.open(u) } }
        [copy, fix, rerun, web].forEach { logBar.addArrangedSubview($0) }
        logBar.spacing = 6; logBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let bottom = NSStackView(views: [logBar, logScroll]); bottom.orientation = .vertical; bottom.spacing = 0
        logBar.isHidden = true

        let split = NSSplitView(); split.isVertical = false; split.dividerStyle = .thin
        split.addArrangedSubview(scroll); split.addArrangedSubview(bottom)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)   // the runs keep their room; the log takes what's left
        let v = NSView()
        for x in [header, split, note] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor), header.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),   // else it and the split share the height
            split.topAnchor.constraint(equalTo: header.bottomAnchor), split.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: v.leadingAnchor), split.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            note.centerXAnchor.constraint(equalTo: v.centerXAnchor), note.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 40),
            note.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -40),
            bottom.heightAnchor.constraint(greaterThanOrEqualToConstant: 120), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        view = v
        track(owner: self) { Workbench.shared.workspaceId } changed: { [weak self] in self?.worktree = $0; self?.reload() }
    }

    private func button(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: "", action: action); b.image = .symbol(symbol, tip); b.isBordered = false; b.toolTip = tip
        b.contentTintColor = .secondaryLabelColor; return b
    }
    private func textButton(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action); b.bezelStyle = .push; b.controlSize = .small; return b
    }

    // MARK: loading

    /// Shown again (another panel was on screen): what ran meanwhile.
    override func viewDidAppear() { super.viewDidAppear(); if !runs.isEmpty { reload() } }

    private func reload() {
        guard let w = worktree else { return }
        poll?.cancel()
        Task {
            let r = await AppModel.shared.tryCall("ci.runs", .obj(["worktreeId": .string(w)]))
            guard w == worktree else { return }
            if let e = r.error {
                branch.stringValue = ""; workflowsButton.isHidden = true
                show(note: e.contains("not found") ? String(localized: "Install the GitHub CLI to see CI runs: brew install gh (glab for GitLab).") : e); return
            }
            branchName = r.value?["branch"]?.string ?? ""
            branch.stringValue = branchName
            // What was open stays open across a refresh, its jobs read again.
            let openRuns = Set(runs.filter { outline.isItemExpanded($0) }.compactMap(\.id))
            let openJobs = Set(runs.flatMap { $0.children ?? [] }.filter { outline.isItemExpanded($0) }.compactMap(\.id))
            let selected = (outline.item(atRow: outline.selectedRow) as? Item)?.id
            runs = ((try? r.value?["runs"]?.decode([CIRuns.Run].self)) ?? []).map { Item(.run($0)) }
            workflows = (try? r.value?["workflows"]?.decode([CIRuns.Workflow].self)) ?? []
            workflowsButton.isHidden = workflows.isEmpty
            show(note: runs.isEmpty ? String(localized: "No CI runs on \(branchName) yet.") : nil)
            outline.reloadData()
            for run in runs where openRuns.contains(run.id ?? -1) {
                await expand(run, openFailed: false)
                for job in run.children ?? [] where openJobs.contains(job.id ?? -1) { outline.expandItem(job) }
                if let job = run.children?.first(where: { $0.id == selected }) { outline.selectRowIndexes([outline.row(forItem: job)], byExtendingSelection: false) }
            }
            // A workflow's latest run failed (what Source Control's CI line shows): open it at the first failed job,
            // with its log (once, so closing it sticks).
            let failing = Set(CIRuns.latest(runs.compactMap { if case .run(let r) = $0.kind { r } else { nil } }).filter(\.failed).map(\.id))
            if let item = runs.first(where: { failing.contains($0.id ?? -1) }), let id = item.id, autoOpened.insert(id).inserted { await expand(item, openFailed: true) }
            pollWhileRunning()
        }
    }

    /// Something still running: look again in a while, as long as the panel is on screen.
    private func pollWhileRunning() {
        guard runs.contains(where: { if case .run(let r) = $0.kind { r.status != "completed" } else { false } }) else { return }
        poll = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.view.window != nil else { return }
            self?.reload()
        }
    }

    private func show(note text: String?) {
        note.stringValue = text ?? ""; note.isHidden = text == nil
        outline.enclosingScrollView?.isHidden = text != nil
        if text != nil { logBar.isHidden = true; log.string = "" }
    }

    private func expand(_ item: Item, openFailed: Bool) async {
        guard case .run(let run) = item.kind, let w = worktree else { return }
        if item.children == nil {
            let jobs = (try? await AppModel.shared.client?.call("ci.jobs", .obj(["worktreeId": .string(w), "run": .int(run.id)]), as: [CIRuns.Job].self)) ?? []
            item.children = jobs.map { j in let i = Item(.job(j, run: run.id)); i.children = j.steps.map { Item(.step($0)) }; return i }
            outline.reloadItem(item, reloadChildren: true)
        }
        outline.expandItem(item)
        if openFailed, let failed = item.children?.first(where: { if case .job(let j, _) = $0.kind { j.failed } else { false } }) {
            outline.expandItem(failed)
            let row = outline.row(forItem: failed)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    private func showLog(_ job: CIRuns.Job, run: Int) {
        guard let w = worktree else { return }
        shownJob = (job, run); logBar.isHidden = false; log.string = ""
        // gh hands out a job's log only once it's over; the next refresh after that brings it.
        guard job.status == "completed" else { shownLog = ""; log.string = String(localized: "The log appears when the job finishes."); return }
        let slow = whileSlow { [weak self] in if self?.shownJob?.job.id == job.id { self?.log.string = String(localized: "Loading the log…") } }
        Task {
            defer { slow.cancel() }
            let r = await AppModel.shared.tryCall("ci.log", .obj(["worktreeId": .string(w), "job": .int(job.id)]))
            guard shownJob?.job.id == job.id else { return }
            shownLog = r.value?.string ?? r.error ?? ""
            log.string = shownLog
            log.scrollToEndOfDocument(nil)
        }
    }

    // MARK: actions

    private func askAgent() {
        guard let w = worktree, let j = shownJob else { return }
        guard FileActions.targetAgent != nil else { Banner.show(String(localized: "No agent in this workspace. Start one with ⌥⌘T, then ask again."), style: .error); return }
        GitFix.send("fixCI", worktree: w, vars: ["check": j.job.name, "error": shownLog])
    }

    private func rerun() {
        guard let w = worktree, let j = shownJob else { return }
        Task {
            if await AppModel.shared.call("ci.rerun", .obj(["worktreeId": .string(w), "run": .int(j.run)])) != nil {
                Banner.show(String(localized: "Re-running the failed jobs")); try? await Task.sleep(for: .seconds(2)); reload()
            }
        }
    }

    @objc private func runWorkflow() {
        let m = NSMenu()
        for wf in workflows { m.add(wf.name) { [weak self] in self?.dispatch(wf) } }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: workflowsButton.bounds.height + 4), in: workflowsButton)
    }

    /// The workflow's inputs as a form, then `gh workflow run` on this branch.
    private func dispatch(_ wf: CIRuns.Workflow) {
        guard let w = worktree else { return }
        let a = NSAlert(); a.messageText = String(localized: "Run “\(wf.name)” on \(branchName)?")
        var fields: [(String, NSView)] = []
        let form = NSGridView()
        for input in wf.inputs {
            let control: NSView
            if !input.options.isEmpty {
                let p = NSPopUpButton(); p.addItems(withTitles: input.options); p.selectItem(withTitle: input.defaultValue); control = p
            } else {
                let f = NSTextField(string: input.defaultValue); f.placeholderString = input.description
                f.widthAnchor.constraint(equalToConstant: 220).isActive = true; control = f
            }
            fields.append((input.name, control))
            form.addRow(with: [NSTextField(labelWithString: input.name + (input.required ? " *" : "")), control])
        }
        if !wf.inputs.isEmpty { a.accessoryView = form }
        a.informativeText = wf.inputs.isEmpty ? String(localized: "It runs on GitHub Actions.") : String(localized: "Inputs from \(wf.file):")
        a.addButton(withTitle: String(localized: "Run")); a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            var inputs: [String: JSONValue] = [:]
            for (k, v) in fields { inputs[k] = .string((v as? NSPopUpButton)?.titleOfSelectedItem ?? (v as? NSTextField)?.stringValue ?? "") }
            if await AppModel.shared.call("ci.dispatch", .obj(["worktreeId": .string(w), "workflow": .string(wf.file), "branch": .string(branchName),
                                                                "inputs": .object(inputs)])) != nil {
                Banner.show(String(localized: "Started \(wf.name)")); try? await Task.sleep(for: .seconds(3)); reload()
            }
        }
    }

    // MARK: outline

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let i = item as? Item else { return runs.count }
        if case .run = i.kind, i.children == nil { return 1 }   // a placeholder until it's opened
        return i.children?.count ?? 0
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let i = item as? Item else { return runs[index] }
        return i.children?[index] ?? Item(.step(.init(name: String(localized: "Loading…"), status: "queued", conclusion: nil)))
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let i = item as? Item else { return false }
        if case .step = i.kind { return false }
        return i.children.map { !$0.isEmpty } ?? true
    }
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { TextSize.of({ if case .run? = (item as? Item)?.kind { 38 } else { 22 } }()) }
    func outlineViewItemWillExpand(_ n: Notification) {
        guard let i = n.userInfo?["NSObject"] as? Item, case .run = i.kind, i.children == nil else { return }
        Task { await expand(i, openFailed: false) }
    }
    func outlineViewSelectionDidChange(_ n: Notification) {
        guard let i = outline.item(atRow: outline.selectedRow) as? Item, case .job(let j, let run) = i.kind else { return }
        if let s = shownJob, s.job.id == j.id, s.job.status == j.status { shownJob = (j, run); return }   // a refresh, nothing new to read
        showLog(j, run: run)
    }

    func outlineView(_ o: NSOutlineView, viewFor c: NSTableColumn?, item: Any) -> NSView? {
        guard let i = item as? Item else { return nil }
        switch i.kind {
        case .run(let r):
            let t = NSTextField(labelWithString: r.title); t.font = .ui(12, weight: .medium); t.lineBreakMode = .byTruncatingTail
            let state = r.status == "completed" ? "" : Self.words(r.status, nil) + " · "
            let s = NSTextField(labelWithString: "\(state)\(r.workflow) · \(r.event) · \(Self.ago(r.createdAt))"); s.font = .ui(11)
            s.textColor = .secondaryLabelColor; s.lineBreakMode = .byTruncatingTail
            let text = NSStackView(views: [t, s]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
            for x in [t, s, text] { x.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
            return row([Self.mark(r.status, r.conclusion), text])
        case .job(let j, _):
            let t = NSTextField(labelWithString: j.name); t.font = .ui(12); t.lineBreakMode = .byTruncatingTail
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            guard j.status != "completed", !j.steps.isEmpty else { return row([Self.mark(j.status, j.conclusion), t]) }
            // How far it got: "6/12" steps.
            let n = NSTextField(labelWithString: "\(j.steps.filter { $0.status == "completed" }.count)/\(j.steps.count)")
            n.font = .uiDigits(11, weight: .regular); n.textColor = .tertiaryLabelColor
            return row([Self.mark(j.status, j.conclusion), t, NSView(), n])
        case .step(let s):
            let t = NSTextField(labelWithString: s.name); t.font = .ui(11); t.lineBreakMode = .byTruncatingTail
            // The step running now reads like a title; done ones grey, the ones still to come quieter still.
            t.textColor = s.status == "in_progress" ? .labelColor : s.status == "completed" ? .secondaryLabelColor : .tertiaryLabelColor
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return row([Self.mark(s.status, s.conclusion), t])
        }
    }

    private func row(_ views: [NSView]) -> NSView {
        let r = NSStackView(views: views); r.spacing = 6; r.alignment = .centerY
        let cell = NSTableCellView(); r.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(r)
        NSLayoutConstraint.activate([r.leadingAnchor.constraint(equalTo: cell.leadingAnchor), r.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                                     r.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    /// ✓ green, ✕ red, the agents' spinning ring while it runs, an empty circle while it waits its turn,
    /// – grey when skipped or cancelled.
    static func mark(_ status: String, _ conclusion: String?) -> NSView {
        let words = Self.words(status, conclusion)
        if status == "in_progress" { let m = StatusMark(size: 14); m.status = .working; m.toolTip = words; return m }
        let (symbol, color): (String, NSColor) = switch (status, conclusion) {
        case ("completed", "success"?): ("checkmark.circle.fill", .systemGreen)
        case ("completed", "skipped"?), ("completed", "cancelled"?), ("completed", "neutral"?): ("minus.circle", .tertiaryLabelColor)
        case ("completed", _): ("xmark.circle.fill", .systemRed)
        default: ("circle", .tertiaryLabelColor)
        }
        let v = NSImageView(image: .symbol(symbol, words)); v.contentTintColor = color; v.toolTip = words
        v.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        return v
    }

    static func words(_ status: String, _ conclusion: String?) -> String {
        switch (status, conclusion) {
        case ("completed", "success"?): String(localized: "Succeeded")
        case ("completed", "skipped"?): String(localized: "Skipped")
        case ("completed", "cancelled"?): String(localized: "Cancelled")
        case ("completed", "neutral"?): String(localized: "Neutral")
        case ("completed", _): String(localized: "Failed")
        case ("in_progress", _): String(localized: "Running")
        case ("waiting", _): String(localized: "Waiting for approval")
        default: String(localized: "Queued")
        }
    }

    static func ago(_ iso: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let d else { return "" }
        return Date().timeIntervalSince(d) < 60 ? shortAgo(d) : String(localized: "\(shortAgo(d)) ago")   // "now", not "now ago"
    }
}
