import AppKit
import Core
import GitKit
import WorkbenchKit

/// Source Control, modeled on VS Code's: branch and sync up top, the commit message, merge / staged / unstaged
/// changes (click → diff), and the history graph. All git work happens in the daemon; this only lays out the answers.
@MainActor
final class SourceControlController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    enum Section: String { case merge = "Merge Changes", staged = "Staged Changes", changes = "Changes", graph = "Graph" }

    final class Node: NSObject {
        enum Kind { case section(Section), file(FileChange, Section), commit(Int), commitFile(String, FileChange), note(String) }
        let kind: Kind
        var children: [Node] = []
        var files: [FileChange] = []   // a section's, also while it's folded
        init(_ k: Kind) { kind = k }
    }

    let outline = NSOutlineView()
    let graphOutline = NSOutlineView()
    private let graphBar = GraphBar()
    private var graphHeight: NSLayoutConstraint?, barHeight: NSLayoutConstraint?
    let branchButton = NSButton()
    private let syncButton = NSButton()
    let message = CommitTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private var messageHeight: NSLayoutConstraint?
    private var commitButton: NSButton?
    /// Beside Commit: its other ways (Commit & Push, Amend), or Push / Pull while it offers to sync.
    private let commitMore = NSButton()
    private let commitMenu = NSMenu(), syncMenu = NSMenu()
    private var moreMenu: NSMenu?
    private var pullItem: NSMenuItem?
    var moreButton: NSButton?
    private var commitArea: NSView?, separator: NSView?
    private let empty = NSTextField(wrappingLabelWithString: "")

    var worktreeId: String?
    var changes: [FileChange] = []
    var info: BranchInfo?
    var commits: [GraphCommit] = []
    private var unpushed = Set<String>()
    /// Commits that just reached the remote, and when each one lands: oldest first, as they left.
    private var landing: [String: Double] = [:]
    /// While a push, pull or sync runs: what the button says, and whether the ↑ arrows pulse.
    var syncing: (title: String, push: Bool)? { didSet { updateCommitButton(); pulseArrows() } }
    private var more = false, limit = 200, loadingMore = false
    private var commitFiles: [String: [FileChange]] = [:]
    private var openCommits = Set<String>()
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "scm.collapsed") ?? [])
    private var roots: [Node] = [], graphRoots: [Node] = []
    private var graphWidth: CGFloat = GraphView.width(lanes: 1)
    private var watcher: FileWatcher?
    private var pending: DispatchWorkItem?
    var busy = false { didSet { updateCommitButton() } }
    private let stats = NSTextField(labelWithString: "")
    private let ciRow = CIStatusRow()
    private var ciRuns: [CIRuns.Run] = []
    /// Where each failed run broke ("job › step"), read once: a finished run doesn't change.
    private var ciFailures: [Int: String] = [:]
    private var ciPoll: Task<Void, Never>?
    /// After a push: the run that was newest then, until a newer one shows up (or the deadline passes).
    private var ciAwaiting: (old: Int?, until: Date)?

    // MARK: view

    override func loadView() {
        branchButton.isBordered = false; branchButton.imagePosition = .imageLeading; branchButton.imageHugsTitle = true
        branchButton.image = Glyph.image("arrow.triangle.branch", size: 14); branchButton.font = .ui(12, weight: .semibold)
        branchButton.lineBreakMode = .byTruncatingMiddle; branchButton.target = self; branchButton.action = #selector(branchMenu)
        branchButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchButton.toolTip = String(localized: "Switch or create a branch")
        syncButton.isBordered = false; syncButton.imagePosition = .imageLeading; syncButton.font = .uiDigits(11, weight: .regular)
        syncButton.contentTintColor = .secondaryLabelColor; syncButton.target = self; syncButton.action = #selector(sync)
        let refresh = iconButton("arrow.clockwise", String(localized: "Refresh")) { [weak self] in self?.reloadAll() }
        let more = iconButton("ellipsis.circle", String(localized: "More Actions")) { [weak self] in self?.showMoreMenu() }
        moreButton = more
        stats.font = .uiDigits(11, weight: .regular); stats.textColor = .secondaryLabelColor
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [branchButton, syncButton, NSView(), stats, refresh, more])
        header.spacing = 6; header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)

        let box = commitBox(); commitArea = box
        let scroll = list(outline), graphScroll = list(graphOutline)
        graphBar.onToggle = { [weak self] in self?.toggle(.graph) }
        graphBar.onResize = { [weak self] in self?.resizeGraph(by: $0) }
        graphBar.onRefresh = { [weak self] in Task { await self?.loadGraph() } }

        empty.alignment = .center; empty.textColor = .secondaryLabelColor; empty.isHidden = true
        let v = NSView()
        let sep = NSBox(); sep.boxType = .separator; separator = sep
        for x in [header, box, sep, scroll, graphBar, graphScroll, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        let gh = graphScroll.heightAnchor.constraint(equalToConstant: 0); gh.priority = .defaultHigh; graphHeight = gh
        let bh = graphBar.heightAnchor.constraint(equalToConstant: 0); barHeight = bh
        let room = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80); room.priority = .init(760)   // the graph gives way first
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor), header.heightAnchor.constraint(equalToConstant: 32),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor), header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            box.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            box.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12), box.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            sep.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: v.leadingAnchor), sep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),   // unset, a rebuilt panel's layout can stretch it tall (and vertical)
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: graphBar.topAnchor), room,
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            graphBar.leadingAnchor.constraint(equalTo: v.leadingAnchor), graphBar.trailingAnchor.constraint(equalTo: v.trailingAnchor), bh,
            graphScroll.topAnchor.constraint(equalTo: graphBar.bottomAnchor), graphScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor), gh,
            graphScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor), graphScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -40)
        ])
        view = v
        updateHeader()   // NSButton's own "Button" title must not show while the branch loads
        track(owner: self) { Workbench.shared.workspaceId } changed: { [weak self] in self?.bind($0) }
        track(owner: self) { FileIcon.revision } changed: { [weak self] _ in
            for o in [self?.outline, self?.graphOutline].compactMap({ $0 }) { o.reloadData(forRowIndexes: IndexSet(0..<o.numberOfRows), columnIndexes: [0]) }
        }
    }

    /// A list in the panel: one column, no header, rows drawn by the cells.
    private func list(_ o: NSOutlineView) -> NSScrollView {
        let col = NSTableColumn(identifier: .init("scm")); col.resizingMask = .autoresizingMask
        o.addTableColumn(col); o.outlineTableColumn = col
        o.headerView = nil; o.style = .plain; o.backgroundColor = .clear
        o.intercellSpacing = .zero; o.indentationPerLevel = 0; o.rowSizeStyle = .custom
        o.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        o.dataSource = self; o.delegate = self; o.target = self; o.action = #selector(clicked(_:))
        let menu = NSMenu(); menu.delegate = self; o.menu = menu
        let s = NSScrollView(); s.documentView = o; s.hasVerticalScroller = true; s.drawsBackground = false; s.autohidesScrollers = true
        return s
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: "", action: action)
        b.image = .symbol(symbol, tip); b.isBordered = false; b.toolTip = tip; b.contentTintColor = .secondaryLabelColor
        b.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        return b
    }

    /// The message field (grows to six lines) and Commit with its split menu.
    private func commitBox() -> NSView {
        message.isRichText = false; message.font = .ui(13); message.drawsBackground = false
        message.textContainerInset = NSSize(width: 4, height: 6); message.allowsUndo = true
        message.isAutomaticQuoteSubstitutionEnabled = false; message.isAutomaticDashSubstitutionEnabled = false
        message.isVerticallyResizable = true; message.autoresizingMask = .width
        message.onCommit = { [weak self] in self?.commit(push: false, amend: false) }
        message.onChange = { [weak self] in self?.messageChanged() }
        let s = NSScrollView(); s.documentView = message; s.drawsBackground = false; s.hasVerticalScroller = false
        placeholder.textColor = .placeholderTextColor; placeholder.font = .ui(13); placeholder.lineBreakMode = .byTruncatingTail
        let field = FieldBox(); field.wantsLayer = true
        commitMenu.add(String(localized: "Commit & Push")) { [weak self] in self?.commit(push: true, amend: false) }
        commitMenu.add(String(localized: "Commit (Amend)")) { [weak self] in self?.commit(push: false, amend: true) }
        syncMenu.add(String(localized: "Push")) { [weak self] in self?.run("git.remote", ["op": "push"], done: String(localized: "Pushed")) }
        pullItem = syncMenu.add(String(localized: "Pull")) { [weak self] in self?.run("git.remote", ["op": "pull"], done: String(localized: "Pulled")) }
        // The panel's main action: the accent colour while there's something to commit (macOS 26's primary tint).
        let cb = NSButton(title: String(localized: "Commit"), target: self, action: #selector(commitPressed))
        cb.image = .symbol("checkmark", String(localized: "Commit")); cb.imagePosition = .imageLeading; cb.imageHugsTitle = true; cb.bezelStyle = .push
        cb.controlSize = .large; cb.toolTip = String(localized: "Commit (⌘↩ in the message)")
        commitMore.image = .symbol("chevron.down", String(localized: "More Commit Actions")); commitMore.bezelStyle = .push
        commitMore.controlSize = .large; commitMore.toolTip = String(localized: "Commit & Push, Amend…")
        commitMore.target = self; commitMore.action = #selector(showCommitMenu)
        commitMore.setContentHuggingPriority(.required, for: .horizontal)
        commitButton = cb
        let buttons = NSStackView(views: [cb, commitMore]); buttons.spacing = 6; buttons.distribution = .fill
        cb.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ciRow.onClick = { [weak self] in self?.openCI() }
        let stack = NSStackView(views: [buttons, ciRow]); stack.orientation = .vertical; stack.spacing = 6   // a hidden CI line takes no room
        let box = NSView()
        for x in [field, s, placeholder, stack] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(x) }
        let h = s.heightAnchor.constraint(equalToConstant: 30); messageHeight = h
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: box.topAnchor), field.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            s.topAnchor.constraint(equalTo: field.topAnchor, constant: 1), s.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -1),
            s.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2), s.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -2), h,
            placeholder.leadingAnchor.constraint(equalTo: s.leadingAnchor, constant: 9), placeholder.topAnchor.constraint(equalTo: s.topAnchor, constant: 7),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: s.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), ciRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return box
    }

    func messageChanged() {
        placeholder.isHidden = !message.string.isEmpty
        if let lm = message.layoutManager, let tc = message.textContainer {
            lm.ensureLayout(for: tc)
            let lines = lm.usedRect(for: tc).height + message.textContainerInset.height * 2
            messageHeight?.constant = min(max(30, ceil(lines)), 6 * 17 + 12)
        }
        updateCommitButton()
    }

    private func updateCommitButton() {
        let staged = changes.contains { $0.staged && !$0.conflicted }
        let branch = info?.current ?? "HEAD"
        placeholder.stringValue = staged || changes.isEmpty ? String(localized: "Message (⌘↩ to commit on “\(branch)”)") : String(localized: "Message (⌘↩ to commit all changes on “\(branch)”)")
        guard let cb = commitButton else { return }
        let next = changes.isEmpty ? nextStep : nil
        // What a commit takes: the staged files, or all of them when none are staged.
        let files = changes.filter { $0.staged && !$0.conflicted }.count
        let count = files > 0 ? files : changes.count
        cb.title = syncing?.title ?? next ?? (count == 0 ? String(localized: "Commit") : String(localized: "Commit \(count) Files"))
        let idle = next == nil && syncing == nil
        cb.image = .symbol(idle ? "checkmark" : info?.upstream == nil ? "icloud.and.arrow.up" : "arrow.triangle.2.circlepath", cb.title)
        moreMenu = next == nil ? commitMenu : syncMenu
        pullItem?.isHidden = info?.upstream == nil
        cb.action = next == nil ? #selector(commitPressed) : #selector(sync)
        cb.toolTip = next == nil ? String(localized: "Commit (⌘↩ in the message)") : syncButton.toolTip
        cb.isEnabled = !busy && (!changes.isEmpty || next != nil)   // with no message, Commit opens a page to write one
        commitMore.isEnabled = cb.isEnabled
        if #available(macOS 26, *) { cb.tintProminence = idle && !changes.isEmpty ? .primary : .automatic }
    }

    @objc private func showCommitMenu() {
        moreMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: commitMore.bounds.height + 4), in: commitMore)
    }

    /// With nothing to commit, the button offers what's left, as in VS Code: sync the commits the remote doesn't
    /// have yet (or pull the ones it has), or publish a branch with no upstream.
    private var nextStep: String? {
        guard let info, info.current != nil else { return nil }
        guard info.upstream != nil else { return info.remote.isEmpty ? nil : String(localized: "Publish Branch") }
        let ahead = info.ahead ?? 0, behind = info.behind ?? 0
        guard ahead + behind > 0 else { return nil }
        return String(localized: "Sync Changes") + (behind > 0 ? " \(behind)↓" : "") + (ahead > 0 ? " \(ahead)↑" : "")
    }

    // MARK: data

    func bind(_ wid: String?) {
        guard wid != worktreeId else { return }
        worktreeId = wid; changes = []; info = nil; commits = []; unpushed = []; commitFiles = [:]; openCommits = []; limit = 200
        ciPoll?.cancel(); ciRuns = []; ciAwaiting = nil; ciRow.show([], failure: nil)
        message.string = ""; messageChanged()
        watcher = AppModel.shared.worktree(wid).flatMap { w in FileWatcher(root: w.path) { [weak self] in if Git.touchesStatus($0) { self?.scheduleReload() } } }
        ChangedFiles.shared.panel = self
        rebuild(); reloadAll()
    }

    /// The workspace this panel shows (and keeps the Source Control badge of).
    var workspace: String? { worktreeId }

    private func scheduleReload() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reloadAll() }
        pending = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func reloadAll() {
        guard let wid = worktreeId, let c = AppModel.shared.client else { return }
        let id = JSONValue.obj(["id": .string(wid)])
        Task {
            do {
                let ch = try await c.call("git.status", id, as: [FileChange].self)
                let br = try await c.call("git.branches", id, as: BranchInfo.self)
                guard wid == worktreeId else { return }   // another workspace is shown now: its own reload is on its way
                let graphStale = br.head != info?.head || br.local != info?.local || br.remote != info?.remote || br.current != info?.current
                    || br.ahead != info?.ahead || br.behind != info?.behind   // a push or fetch moved origin/…
                let changed = ch != changes || br != info
                // A push (or a publish) starts CI: wait for its run to show up.
                if let old = info, br.upstream != nil, br.current == old.current, old.upstream == nil || (br.ahead ?? 0) < (old.ahead ?? 0) {
                    ciAwaiting = (ciRuns.first?.id, Date().addingTimeInterval(45))
                }
                changes = ch; info = br; showError(nil)
                ChangedFiles.shared.report(wid, ch.count)
                updateHeader(); updateCommitButton()
                let stats = ch.isEmpty ? nil : try? await c.call("git.lineStats", id, as: LineStats.self)
                guard wid == worktreeId else { return }
                showStats(stats)
                if graphStale || commits.isEmpty { loadCI(); await loadGraph() } else if changed { rebuildChanges() }
            } catch {
                guard wid == worktreeId else { return }
                changes = []; info = nil; commits = []
                showError((error as? RPCError)?.message ?? "\(error)")
                updateHeader(); rebuild()
            }
            NotificationCenter.default.post(name: .kelpGitChanged, object: wid)
        }
    }

    /// Nothing git can show here: say why instead of an empty commit box.
    private func showError(_ message: String?) {
        for v in [commitArea, separator, moreButton] { v?.isHidden = message != nil }
        outline.enclosingScrollView?.isHidden = message != nil
        empty.isHidden = message == nil
        layoutGraph()
        guard let message else { return }
        let notRepo = message.contains("not a git repository")
        let s = NSMutableAttributedString(string: notRepo ? String(localized: "Not a Git Repository") : String(localized: "Git Isn't Available"),
                                          attributes: [.font: NSFont.ui(13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: "\n" + (notRepo ? String(localized: "This folder isn't under git version control.") : message),
                                    attributes: [.font: NSFont.ui(11), .foregroundColor: NSColor.tertiaryLabelColor]))
        if let fix = FixRecipes.fix(for: message) {   // the command that makes git work again, selectable
            s.append(NSAttributedString(string: String(localized: "\n\nFix it in Terminal:\n") + fix.command,
                                        attributes: [.font: NSFont.monospacedSystemFont(ofSize: TextSize.of(11), weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.paragraphSpacing = 4
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        empty.attributedStringValue = s
    }

    /// Shown again (another panel was on screen): what CI did meanwhile.
    override func viewDidAppear() { super.viewDidAppear(); if !ciRuns.isEmpty { loadCI() } }

    /// The CI line under Commit. While a run goes on, or a push's run hasn't shown up yet, it looks again
    /// as long as the panel is on screen. No upstream, no gh / glab, no runs: no line.
    private func loadCI() {
        ciPoll?.cancel()
        guard let wid = worktreeId, info?.upstream != nil else { ciRuns = []; ciRow.show([], failure: nil); return }
        ciPoll = Task { [weak self] in
            let r = await AppModel.shared.tryCall("ci.runs", .obj(["worktreeId": .string(wid)]))
            guard let self, !Task.isCancelled, wid == worktreeId else { return }
            ciRuns = (try? r.value?["runs"]?.decode([CIRuns.Run].self)) ?? []
            let latest = CIRuns.latest(ciRuns)
            ciRow.show(latest, failure: nil)
            if let failed = latest.first(where: \.failed) {
                if ciFailures[failed.id] == nil { ciFailures[failed.id] = await failurePlace(wid, run: failed.id) }
                guard !Task.isCancelled, wid == worktreeId else { return }
                ciRow.show(latest, failure: ciFailures[failed.id])
            }
            let waiting = ciAwaiting.map { self.ciRuns.first?.id == $0.old && Date() < $0.until } ?? false
            if !waiting { ciAwaiting = nil }
            guard waiting || latest.contains(where: { $0.status != "completed" }) else { return }
            try? await Task.sleep(for: .seconds(waiting ? 5 : 10))
            guard !Task.isCancelled, view.window != nil else { return }
            loadCI()
        }
    }

    /// "test › Run swift test": the first failed job and its failed step.
    private func failurePlace(_ wid: String, run: Int) async -> String? {
        let r = await AppModel.shared.tryCall("ci.jobs", .obj(["worktreeId": .string(wid), "run": .int(run)]))
        guard let job = (try? r.value?.decode([CIRuns.Job].self))?.first(where: \.failed) else { return nil }
        return ([job.name] + (job.steps.first(where: \.failed).map { [$0.name] } ?? [])).joined(separator: " › ")
    }

    /// The details live in the CI Runs panel (it opens the failed job's log by itself); without it, the run's page.
    private func openCI() {
        if ExtensionRegistry.shared.all.panels.contains(where: { $0.id == "ci" }) { Workbench.window?.showInspector(panel: "ci") }
        else if let run = CIRuns.latest(ciRuns).first(where: \.failed) ?? ciRuns.first { Workbench.open(run.url) }
    }

    func loadGraph() async {
        guard let wid = worktreeId, let c = AppModel.shared.client else { return }
        let r = try? await c.call("git.graph", .obj(["id": .string(wid), "limit": .int(limit)]))
        guard wid == worktreeId else { return }
        if let r, let list = Perf.measure("graph decode", { try? r["commits"]?.decode([GraphCommit].self) }) {
            commits = list; more = r["more"]?.bool == true
            let before = unpushed
            unpushed = Git.unpushed(list, remotes: Set(info?.remote ?? []))
            let landed = list.filter { before.contains($0.hash) && !unpushed.contains($0.hash) }.reversed()
            landing = Dictionary(uniqueKeysWithValues: landed.enumerated().map { ($1.hash, Double(min($0, 12)) * 0.05) })
            let lanes = list.map { c in ([c.lane] + c.top.flatMap { $0 } + c.bottom.flatMap { $0 }).max() ?? 0 }.max() ?? 0
            graphWidth = GraphView.width(lanes: min(lanes + 1, GraphView.maxLanes))
        }
        loadingMore = false
        Perf.measure("graph rows") { rebuild() }
        // Landed once: a later rebuild (a commit unfolded) shows them as they are now.
        if !landing.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.landing = [:] } }
    }

    private func pulseArrows() {
        for r in 0..<graphOutline.numberOfRows {
            (graphOutline.view(atColumn: 0, row: r, makeIfNecessary: false) as? CommitCell)?.pulse(syncing?.push == true)
        }
    }

    /// "+120 −30" for everything not committed yet; hovering splits it into code, tests and generated files.
    private func showStats(_ s: LineStats?) {
        guard let s, s.totalAdded + s.totalRemoved > 0 else { stats.isHidden = true; return }
        stats.isHidden = false
        stats.attributedStringValue = RowBadges.changes(s) ?? NSAttributedString()
        let names: [LineStats.Kind: String] = [.code: String(localized: "Code"), .tests: String(localized: "Tests"), .generated: String(localized: "Generated")]
        stats.toolTip = String(localized: "Not committed yet\n") + LineStats.Kind.allCases.compactMap { k in
            let a = s.added[k] ?? 0, r = s.removed[k] ?? 0
            return a + r == 0 ? nil : "\(names[k] ?? ""): +\(a) −\(r)"
        }.joined(separator: "\n")
    }

    private func updateHeader() {
        guard let info else { branchButton.title = ""; syncButton.isHidden = true; return }
        branchButton.title = info.current ?? String(localized: "Detached at \(info.head ?? "?")")
        if info.merging { branchButton.title += String(localized: " (Merging)") }
        if let up = info.upstream {
            syncButton.isHidden = false; syncButton.image = .symbol("arrow.triangle.2.circlepath", String(localized: "Sync"))
            syncButton.title = "\(info.behind ?? 0)↓ \(info.ahead ?? 0)↑"; syncButton.toolTip = String(localized: "Pull from and push to \(up)")
        } else if info.current != nil, !info.remote.isEmpty {
            syncButton.isHidden = false; syncButton.image = .symbol("icloud.and.arrow.up", String(localized: "Publish Branch"))
            syncButton.title = ""; syncButton.toolTip = String(localized: "Publish Branch")
        } else { syncButton.isHidden = true }
    }

    // MARK: tree

    private func rebuild() { rebuildChanges(); rebuildGraph() }

    /// Sections fold through `collapsed`, not the outline's own expansion state, which goes stale across reloads
    /// (a click then "expanded" a section already open).
    private func rebuildChanges() {
        var out: [Node] = []
        func section(_ s: Section, _ files: [FileChange]) {
            guard !files.isEmpty else { return }
            let n = Node(.section(s)); n.files = files
            if !collapsed.contains(s.rawValue) { n.children = files.map { Node(.file($0, s)) } }
            out.append(n)
        }
        let g = changes.grouped
        section(.merge, g.merge)
        section(.staged, g.staged)
        section(.changes, g.changes)
        if changes.isEmpty, info != nil { out.append(Node(.note(String(localized: "No changes")))) }
        roots = out
        outline.reloadData(); outline.expandItem(nil, expandChildren: true)
    }

    private func rebuildGraph() {
        graphRoots = commits.indices.map { i in
            let n = Node(.commit(i)), h = commits[i].hash
            if openCommits.contains(h) { n.children = (commitFiles[h] ?? []).map { Node(.commitFile(h, $0)) } }
            return n
        }
        graphOutline.reloadData(); graphOutline.expandItem(nil, expandChildren: true)
        layoutGraph()
    }

    /// The graph is a pane of its own under the changes, as in VS Code, so a long list of changes never pushes it
    /// out of sight: its header folds it, dragging the header sizes it.
    private func layoutGraph() {
        let has = !commits.isEmpty && empty.isHidden, open = has && !collapsed.contains(Section.graph.rawValue)
        graphBar.isHidden = !has; graphBar.expanded = open
        graphOutline.enclosingScrollView?.isHidden = !open
        barHeight?.constant = has ? GraphBar.height : 0
        graphHeight?.constant = open ? UserDefaults.standard.object(forKey: "scm.graphHeight") as? CGFloat ?? 260 : 0
    }

    private func resizeGraph(by dy: CGFloat) {
        guard let gh = graphHeight, gh.constant > 0, let changes = outline.enclosingScrollView, let graph = graphOutline.enclosingScrollView else { return }
        gh.constant = min(max(60, graph.frame.height + dy), changes.frame.height + graph.frame.height - 80)
        UserDefaults.standard.set(gh.constant, forKey: "scm.graphHeight")
    }

    private func toggle(_ s: Section) {
        if collapsed.contains(s.rawValue) { collapsed.remove(s.rawValue) } else { collapsed.insert(s.rawValue) }
        UserDefaults.standard.set(Array(collapsed), forKey: "scm.collapsed")
        if s == .graph { layoutGraph() } else { rebuildChanges() }
    }

    private func roots(of o: NSOutlineView) -> [Node] { o === graphOutline ? graphRoots : roots }
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots(of: o).count }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[i] ?? roots(of: o)[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as? Node)?.kind {
        case .section?, .note?: TextSize.of(26)
        default: TextSize.of(22)
        }
    }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if case .note? = (item as? Node)?.kind { return false }
        return true
    }
    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { HoverRowView() }

    func outlineView(_ o: NSOutlineView, viewFor tc: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        switch n.kind {
        case .section(let s):
            return SectionCell(title: loc(s.rawValue), count: n.files.count, expanded: !collapsed.contains(s.rawValue), actions: sectionActions(s, n))
        case .file(let f, let s):
            return FileCell(f, letter: Self.letter(f, s), indent: 16, actions: fileActions(f, s))
        case .commit(let i):
            if more, !loadingMore, i >= commits.count - 30 { loadMore() }
            let c = commits[i]
            let pushed: Bool? = info?.remote.isEmpty ?? true ? nil : !unpushed.contains(c.hash)
            let cell = CommitCell(c, graphWidth: graphWidth, isHead: c.hash.hasPrefix(info?.head ?? "\u{0}"), pushed: pushed, landsAfter: landing[c.hash])
            if syncing?.push == true { cell.pulse(true) }
            return cell
        case .commitFile(let h, let f):
            let cell = FileCell(f, letter: Self.letter(f, .graph), indent: graphWidth + 4, actions: [])
            // The lanes below the commit run on through its expanded files, as in VS Code.
            let g = GraphView(); g.through = Array(Set(commits.first { $0.hash == h }?.bottom.compactMap(\.last) ?? []))
            g.frame = NSRect(x: 6, y: 0, width: graphWidth, height: 22); g.autoresizingMask = [.height]
            cell.addSubview(g)
            return cell
        case .note(let t):
            return NoteCell(t)
        }
    }

    private func loadMore() {
        loadingMore = true; limit += 200
        DispatchQueue.main.async { Task { [weak self] in await self?.loadGraph() } }
    }

    // MARK: clicks

    @objc private func clicked(_ o: NSOutlineView) {
        guard let n = o.item(atRow: o.clickedRow) as? Node else { return }
        switch n.kind {
        case .section(let s): toggle(s)
        case .file(let f, let s): open(f, s)
        case .commit(let i): toggle(commit: commits[i].hash)
        case .commitFile(let h, let f): if let w = worktreeId { Workbench.open(DiffTab.uri(w, file: f.path, commit: h)) }
        case .note: break
        }
    }

    func open(_ f: FileChange, _ s: Section) {
        guard let w = worktreeId else { return }
        if s == .merge { openFile(f); return }
        Workbench.open(DiffTab.uri(w, file: f.path, source: s == .staged ? "staged" : "unstaged"))
    }
    func openFile(_ f: FileChange) {
        if let w = AppModel.shared.worktree(worktreeId) { Workbench.open(TabURI.file(w.path + "/" + f.path)) }
    }

    private func toggle(commit hash: String) {
        if openCommits.contains(hash) { openCommits.remove(hash); rebuildGraph(); return }
        openCommits.insert(hash)
        guard commitFiles[hash] == nil, let wid = worktreeId else { rebuildGraph(); return }
        Task {
            let files = (try? await AppModel.shared.client?.call("git.commitFiles", .obj(["id": .string(wid), "commit": .string(hash)]), as: [FileChange].self)) ?? []
            guard wid == worktreeId else { return }
            commitFiles[hash] = files
            rebuildGraph()
        }
    }

    // MARK: status letters (VS Code's colors)

    static func letter(_ f: FileChange, _ s: Section) -> (String, NSColor) {
        let l = f.letter(inWorktree: s == .changes, merging: s == .merge)
        switch l {
        case "!", "D": return (l, .systemRed)
        case "U", "A": return (l, .systemGreen)
        case "R", "C": return (l, .systemBlue)
        default: return (l, .systemOrange)
        }
    }
}

// MARK: - cells
