import AppKit
import Core
import GitKit

/// Reading the workspace's status, history and remote state from the daemon.
extension SourceControlController {
    func bind(_ wid: String?) {
        guard wid != worktreeId else { return }
        worktreeId = wid; changes = []; info = nil; commits = []; unpushed = []; commitFiles = [:]; openCommits = []; limit = 200
        ciPoll?.cancel(); ciRuns = []; ciAwaiting = nil; ciRow.show([], failure: nil)
        message.string = ""; messageChanged()
        watcher = AppModel.shared.worktree(wid).flatMap { w in FileWatcher(root: w.path) { [weak self] in if Git.touchesStatus($0) { self?.scheduleReload() } } }
        ChangedFiles.shared.panel = self
        rebuild(); reloadAll()
    }

    /// The workspace this panel shows and keeps the Source Control badge of; out of the window it reads nothing,
    /// so the badge counts by itself.
    var workspace: String? { view.window == nil ? nil : worktreeId }

    private func scheduleReload() { pending.after(0.4) { [weak self] in self?.reloadAll() } }

    func reloadAll() {
        // Swapped out of the inspector: no git until it shows again.
        guard view.window != nil else { stale = true; return }
        stale = false
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
    override func viewDidAppear() {
        super.viewDidAppear()
        if stale { reloadAll() }
        if !ciRuns.isEmpty { loadCI() }
    }

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
    func openCI() {
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

    func pulseArrows() {
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

    func updateHeader() {
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
}
