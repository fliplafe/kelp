import AppKit
import Core
import Agents

/// One workspace (worktree): a tab strip over the selected tab's content. Tabs hold agents/terminals (split freely),
/// Changes, Files, Browser, Issues & PRs or a chat — everything about the task in one place.
@MainActor
final class WorkspaceViewController: NSViewController {
    private(set) var worktree: Worktree
    let model: WorkspaceTabs
    private let tabBar = TabBar()
    private let body = NSView()
    private var panes: [String: PaneView] = [:]
    private var renderedTab: String?
    private var focusedSession: String?
    private lazy var diff: DiffViewController = { let d = DiffViewController(); d.currentSession = { [weak self] in self?.currentSession }; addChild(d); return d }()
    private lazy var files: FilesViewController = { let f = FilesViewController(); f.currentSession = { [weak self] in self?.currentSession }; addChild(f); return f }()
    /// One browser for all workspaces (it keeps tabs per worktree); it moves into whichever workspace shows it.
    private var browser: BrowserViewController { BrowserViewController.shared }
    private lazy var tasks: TasksViewController = { let t = TasksViewController(); addChild(t); return t }()
    private var chats: [String: ChatViewController] = [:]
    private var start: StartView?

    init(worktree: Worktree) {
        self.worktree = worktree
        model = WorkspaceTabs(worktreeId: worktree.id)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        for x in [tabBar, body] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: v.topAnchor), tabBar.leadingAnchor.constraint(equalTo: v.leadingAnchor), tabBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            body.topAnchor.constraint(equalTo: tabBar.bottomAnchor), body.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: v.trailingAnchor), body.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
        tabBar.onSelect = { [weak self] id in self?.model.selectedId = id; self?.model.save(); self?.render() }
        tabBar.onClose = { [weak self] id in self?.closeTab(id) }
        tabBar.onMove = { [weak self] from, to in self?.model.move(from: from, to: to); self?.render() }
        tabBar.onMenu = { [weak self] id in self?.menu(for: id) }
        tabBar.addMenu = { [weak self] in self?.newTabMenu() ?? NSMenu() }
        // A dev server printed its URL: give the workspace a Browser tab (without pulling focus away).
        NotificationCenter.default.addObserver(forName: .krillDevServerURL, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, n.userInfo?["worktree"] as? String == self.worktree.id, !self.model.tabs.contains(where: { $0.kind == .browser }) else { return }
                self.model.add(.browser); self.renderTabBar()
            }
        }
        refresh()
    }

    var currentSession: String? {
        if let f = focusedSession, model.selected?.sessions.contains(f) == true { return f }
        if let s = model.selected?.sessions.first { return s }
        // Changes / Browser tabs: the workspace's agent.
        return AppModel.shared.sessions.last { $0.worktreeId == worktree.id && $0.status != .exited && $0.agent != "shell" }?.id
            ?? AppModel.shared.sessions.last { $0.worktreeId == worktree.id && $0.status != .exited }?.id
    }

    // MARK: rendering

    /// After daemon changes: keep layout, drop dead panes, add sessions made elsewhere, refresh titles and status.
    func refresh() {
        if let w = AppModel.shared.worktree(worktree.id) { worktree = w }
        let before = model.tabs
        model.reconcile(live: AppModel.shared.sessions.filter { $0.worktreeId == worktree.id })
        for (sid, p) in panes { if let s = AppModel.shared.session(sid) { p.update(s) } }
        if model.tabs != before || renderedTab != model.selected?.id || renderedTab == nil && start == nil { render() } else { renderTabBar() }
    }

    private func renderTabBar() {
        tabBar.set(model.tabs.map(item), selected: model.selected?.id)
        tabBar.isHidden = model.tabs.isEmpty
    }

    private func item(_ t: WorkTab) -> TabBar.Item {
        switch t.kind {
        case .terminal:
            let ss = t.sessions.compactMap { AppModel.shared.session($0) }
            let first = ss.first
            let name = first.map { s in s.title.isEmpty ? (s.agent == "shell" ? "Terminal" : AppModel.shared.agents.first { $0.id == s.agent }?.name ?? s.displayTitle) : s.title } ?? "Terminal"
            let title = name + (ss.count > 1 ? "  +\(ss.count - 1)" : "")
            // The tab shows the most urgent state among its panes.
            let order: [AgentStatus] = [.waiting, .working, .done, .idle, .hibernated, .exited]
            let st = ss.filter { $0.agent != "shell" }.map(\.status).min { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
            return .init(id: t.id, title: title, icon: AgentCatalog.symbol(first?.agent), status: st, unread: ss.contains(where: \.unread))
        case .changes: return .init(id: t.id, title: "Changes", icon: "plusminus", status: nil, unread: false)
        case .files: return .init(id: t.id, title: "Files", icon: "doc.text", status: nil, unread: false)
        case .browser: return .init(id: t.id, title: "Browser", icon: "safari", status: nil, unread: false)
        case .tasks: return .init(id: t.id, title: "Issues & PRs", icon: "checklist", status: nil, unread: false)
        case .chat: return .init(id: t.id, title: "Chat", icon: "bubble.left.and.text.bubble.right", status: nil, unread: false)
        }
    }

    func render() {
        renderTabBar()
        body.subviews.forEach { $0.removeFromSuperview() }
        guard let tab = model.selected else { renderedTab = nil; showStart(); return }
        start = nil; renderedTab = tab.id
        let content: NSView
        switch tab.kind {
        case .terminal(let layout):
            let size = body.bounds.width > 0 ? body.bounds.size : NSSize(width: 1000, height: 700)
            content = build(layout, size: size)
        case .changes: content = diff.view; diff.show(worktree: worktree.id)
            // (child controllers keep the responder chain and appearance callbacks working)
        case .files: content = files.view; files.show(worktree: worktree.id)
        case .browser:
            addChild(browser); browser.currentSession = { [weak self] in self?.currentSession }
            content = browser.view; browser.show(worktree: worktree.id)
        case .tasks: content = tasks.view; tasks.show(worktree: worktree.id)
        case .chat(let id):
            let c = chats[id] ?? ChatViewController(chatId: id, worktree: worktree)
            if chats[id] == nil { chats[id] = c; addChild(c) }
            content = c.view
        }
        pin(content)
        // Drop panes that no longer appear anywhere in this workspace.
        let used = Set(model.tabs.flatMap(\.sessions))
        for sid in panes.keys where !used.contains(sid) { panes[sid] = nil }
        DispatchQueue.main.async { [weak self] in self?.focusContent() }
    }

    private func pin(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: body.topAnchor), v.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: body.leadingAnchor), v.trailingAnchor.constraint(equalTo: body.trailingAnchor)])
    }

    private func focusContent() {
        guard let tab = model.selected else { start?.focus(); return }
        switch tab.kind {
        case .terminal: (focusedSession.flatMap { panes[$0] } ?? tab.sessions.first.flatMap { panes[$0] })?.focus()
        case .chat(let id): chats[id]?.focusInput()
        default: break
        }
    }

    /// Children start with equal frames; NSSplitView then keeps their proportions as the window resizes.
    private func build(_ n: LayoutNode, size: NSSize) -> NSView {
        switch n {
        case .pane(let sid): return pane(sid, inSplit: false)
        case .split(let vertical, let kids):
            let sv = NSSplitView(); sv.isVertical = vertical; sv.dividerStyle = .thin
            sv.frame = NSRect(origin: .zero, size: size)
            let n = CGFloat(kids.count), gap = sv.dividerThickness * (n - 1)
            let child = vertical ? NSSize(width: (size.width - gap) / n, height: size.height) : NSSize(width: size.width, height: (size.height - gap) / n)
            for k in kids {
                let v = if case .pane(let sid) = k { pane(sid, inSplit: true) } else { build(k, size: child) }
                v.translatesAutoresizingMaskIntoConstraints = true
                v.frame = NSRect(origin: .zero, size: child)
                sv.addArrangedSubview(v)
            }
            return sv
        }
    }

    private func pane(_ sid: String, inSplit: Bool) -> NSView {
        let p: PaneView
        if let existing = panes[sid] { p = existing } else if let s = AppModel.shared.session(sid) {
            p = PaneView(session: s)
            p.onClose = { [weak self] in self?.closePane($0.sessionId) }
            p.onFocus = { [weak self] in self?.focusedSession = $0.sessionId }
            p.onRestart = { [weak self] in self?.restart($0.sessionId) }
            p.onDrop = { [weak self] dragged, target, edge in
                self?.model.movePane(dragged, beside: target.sessionId, vertical: edge == .left || edge == .right, before: edge == .left || edge == .top)
                self?.render()
            }
            panes[sid] = p
        } else { return NSView() }
        p.removeFromSuperview()
        p.showsHeader = inSplit
        return p
    }

    private func showStart() {
        let s = StartView(worktree: worktree)
        s.onStart = { [weak self] agent, prompt, extra in self?.newAgent(agent, prompt: prompt, extra: extra) }
        s.onOpen = { [weak self] kind in self?.open(kind) }
        s.onTerminal = { [weak self] in self?.newTerminal() }
        start = s
        pin(s)
        DispatchQueue.main.async { s.focus() }
    }

    // MARK: actions

    func closeCurrentTab() { if let t = model.selected { closeTab(t.id) } }

    func newAgent(_ agent: String?, prompt: String? = nil, extra: [String: JSONValue] = [:], split: Bool = false, vertical: Bool = true) {
        var p = extra; p["worktreeId"] = .string(worktree.id)
        if let agent { p["agent"] = .string(agent) }
        if let prompt, !prompt.isEmpty { p["prompt"] = .string(prompt) }
        if p["mode"] == nil, agent != "shell", UserDefaults.standard.string(forKey: "permissionMode") == "yolo" { p["mode"] = "yolo" }
        Task {
            guard let r = await AppModel.shared.call("session.create", .object(p)), let s = try? r.decode(Session.self) else { return }
            if !AppModel.shared.sessions.contains(where: { $0.id == s.id }) { AppModel.shared.sessions.append(s) }
            let tab = split && model.selected?.kind.isTerminal == true ? model.selected?.id : nil
            model.addSession(s.id, splitting: tab, vertical: vertical, beside: currentSession)
            focusedSession = s.id
            render()
        }
    }

    func newTerminal(split: Bool = false, vertical: Bool = true) { newAgent("shell", split: split, vertical: vertical) }

    func open(_ kind: TabKind) { model.open(kind); render() }

    func startChat() {
        ChatViewController.start(worktree: worktree) { [weak self] id in self?.model.open(.chat(id)); self?.render() }
    }

    func closeCurrent() {
        guard let tab = model.selected else { return }
        if tab.kind.isTerminal, let s = currentSession, tab.sessions.count > 1 { closePane(s) } else { closeTab(tab.id) }
    }

    private func closeTab(_ id: String) {
        guard let tab = model.tabs.first(where: { $0.id == id }) else { return }
        // Agents keep running in the daemon only if the user says so; closing a tab ends its sessions, like a terminal.
        for s in tab.sessions { Task { await AppModel.shared.call("session.kill", .obj(["id": .string(s)])) } }
        model.close(id)
        render()
    }

    private func closePane(_ sid: String) {
        Task { await AppModel.shared.call("session.kill", .obj(["id": .string(sid)])) }
        model.removeSession(sid); panes[sid] = nil
        render()
    }

    private func restart(_ sid: String) {
        Task {
            guard let r = await AppModel.shared.call("session.restart", .obj(["id": .string(sid)])), let s = try? r.decode(Session.self) else { return }
            AppModel.shared.sessions.removeAll { $0.id == sid || $0.id == s.id }; AppModel.shared.sessions.append(s)
            model.replaceSession(sid, with: s.id); panes[sid] = nil
            render()
        }
    }

    /// Leaving the workspace: drop terminal views so their `krill attach` bridges end and idle agents can hibernate.
    func suspend() {
        body.subviews.forEach { $0.removeFromSuperview() }
        panes.removeAll(); renderedTab = nil; start = nil
    }

    /// A session made elsewhere (task, fork, history, dev server…) gets its own tab here.
    func add(session s: Session, split: Bool = false) {
        AppModel.shared.sessions.removeAll { $0.id == s.id }; AppModel.shared.sessions.append(s)
        let tab = split && model.selected?.kind.isTerminal == true ? model.selected?.id : nil
        model.addSession(s.id, splitting: tab, vertical: true, beside: currentSession)
        focusedSession = s.id
        render()
    }

    func focusNeighbor(step: Int) {
        guard case .terminal(let l)? = model.selected?.kind, let cur = currentSession, let n = l.neighbor(of: cur, step: step) else { return }
        focusedSession = n; panes[n]?.focus()
    }

    func selectTab(offset: Int) { model.select(offset: offset); render() }
    func selectTab(index: Int) { if model.tabs.indices.contains(index) { model.selectedId = model.tabs[index].id; model.save(); render() } }
    func focus(session sid: String) {
        guard let t = model.tabs.first(where: { $0.sessions.contains(sid) }) else { return }
        model.selectedId = t.id; focusedSession = sid; render()
    }

    private func menu(for id: String) -> NSMenu? {
        guard let tab = model.tabs.first(where: { $0.id == id }) else { return nil }
        let m = NSMenu()
        func add(_ t: String, _ f: @escaping () -> Void) { let i = m.addItem(withTitle: t, action: #selector(ClosureTarget.fire), keyEquivalent: ""); let c = ClosureTarget(f); i.target = c; i.representedObject = c }
        if let sid = tab.sessions.first {
            add("Rename…") {
                let cur = AppModel.shared.session(sid)?.title ?? ""
                guard let t = prompt("Rename tab", "Leave empty to name it from the task automatically.", initial: cur) else { return }
                Task { await AppModel.shared.call("session.rename", .obj(["id": .string(sid), "title": .string(t)])) }
            }
            add("Restart") { [weak self] in self?.restart(sid) }
            add("Copy Context") {
                Task { if let t = await AppModel.shared.call("session.context", .obj(["id": .string(sid)]))?.string { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) } }
            }
            m.addItem(.separator())
            add("Split Right") { [weak self] in self?.model.selectedId = id; self?.newTerminal(split: true, vertical: true) }
            add("Split Down") { [weak self] in self?.model.selectedId = id; self?.newTerminal(split: true, vertical: false) }
            m.addItem(.separator())
            add("Fork to New Workspace…") { AgentActions.fork(sid) }
            add("Hand Off to Another Agent…") { AgentActions.handoff(sid) }
            m.addItem(.separator())
        }
        add("Close Tab") { [weak self] in self?.closeTab(id) }
        add("Close Other Tabs") { [weak self] in
            guard let self else { return }
            for t in self.model.tabs where t.id != id { self.closeTab(t.id) }
        }
        return m
    }

    /// The "+" menu: agents first (installed ones), then other tab kinds.
    func newTabMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ sym: String, key: String = "", mods: NSEvent.ModifierFlags = [], _ f: @escaping () -> Void) {
            let i = m.addItem(withTitle: t, action: #selector(ClosureTarget.fire), keyEquivalent: key); i.keyEquivalentModifierMask = mods
            let c = ClosureTarget(f); i.target = c; i.representedObject = c
            i.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        }
        let agents = AgentCatalog.installed(AppModel.shared.agents)
        if agents.isEmpty {
            let i = m.addItem(withTitle: "No agent CLIs found on PATH", action: nil, keyEquivalent: ""); i.isEnabled = false
        }
        for a in agents { add(a.name, AgentCatalog.symbol(a.id)) { [weak self] in self?.newAgent(a.id) } }
        add("Agent with Options…", "slider.horizontal.3") { [weak self] in if let w = self?.worktree.id { AgentActions.newAgent(worktree: w) } }
        m.addItem(.separator())
        add("Terminal", "terminal") { [weak self] in self?.newTerminal() }
        add("Chat with Claude", "bubble.left.and.text.bubble.right") { [weak self] in self?.startChat() }
        m.addItem(.separator())
        add("Changes", "plusminus") { [weak self] in self?.open(.changes) }
        add("Files", "doc.text") { [weak self] in self?.open(.files) }
        add("Browser", "safari") { [weak self] in self?.open(.browser) }
        add("Issues & PRs", "checklist") { [weak self] in self?.open(.tasks) }
        return m
    }

    // Exposed for menus / other screens.
    /// These open their tab first, so menu commands land where the user can see them.
    var filesController: FilesViewController { open(.files); return files }
    var browserController: BrowserViewController { open(.browser); return browser }
    var diffController: DiffViewController { diff }
    var visiblePanes: [PaneView] { Array(panes.values) }
    var selectedKind: TabKind? { model.selected?.kind }
    var hasFiles: Bool { model.tabs.contains { $0.kind == .files } }
}
