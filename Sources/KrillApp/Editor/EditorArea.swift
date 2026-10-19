import AppKit
import Core

enum SplitDirection: String { case right, down }

/// One workspace's editor area: groups of tabs in a split tree. Tabs are made by the providers extensions register.
@MainActor
final class EditorArea: NSViewController {
    let workspaceId: String
    private(set) var layout: WorkspaceLayout
    private var contents: [String: TabContent] = [:]       // by tab id
    private var groupViews: [String: GroupView] = [:]
    private var renders = 0
    private var start: StartView?
    private var responderObservation: NSKeyValueObservation?
    private var saveWork: DispatchWorkItem?
    private var reconciledOnce = false

    var worktree: Worktree? { AppModel.shared.worktree(workspaceId) }

    init(workspaceId: String) {
        self.workspaceId = workspaceId
        layout = WorkspaceLayout.load(workspaceId)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        track { ExtensionRegistry.shared.revision } changed: { [weak self] _ in self?.extensionsChanged() }
    }

    /// Turning an extension off takes its open tabs' content with it (they say how to turn it back on); turning it on
    /// brings the content back.
    private func extensionsChanged() {
        let stale = contents.filter { (ExtensionRegistry.shared.tabProvider(for: $0.value.uri) != nil) == ($0.value is UnavailableTab) }.map(\.key)
        guard !stale.isEmpty else { return }
        stale.forEach { contents[$0] = nil }
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        responderObservation = view.window?.observe(\.firstResponder, options: [.new]) { [weak self] w, _ in
            MainActor.assumeIsolated { self?.responderChanged(w.firstResponder) }
        }
        publishFocus()
    }
    override func viewWillDisappear() { super.viewWillDisappear(); responderObservation = nil }

    // MARK: rendering

    func render() {
        view.subviews.forEach { $0.removeFromSuperview() }
        guard let root = layout.root, !layout.allTabs.isEmpty else { showStart(); return }
        start = nil
        let v = build(root)
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: view.topAnchor), v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: view.leadingAnchor), v.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        // The focused group now, the others one per run-loop turn: restoring a browser, files and terminals together
        // would otherwise hold the main thread for 100–200 ms. A newer render takes over the rest.
        renders += 1
        let gen = renders, first = layout.focusedGroup?.id ?? root.sessions.first
        if let first { refreshGroup(first) }
        var rest = root.sessions.filter { $0 != first }
        func next() {
            guard !rest.isEmpty else { return }
            let gid = rest.removeFirst()
            DispatchQueue.main.async { [weak self] in
                guard let self, renders == gen else { return }
                refreshGroup(gid); next()
            }
        }
        next()
        for gid in groupViews.keys where layout.groups[gid] == nil { groupViews[gid] = nil }
        let live = Set(layout.allTabs.map(\.id))
        for id in contents.keys where !live.contains(id) { contents[id] = nil }
        scheduleSave()
    }

    private func build(_ n: LayoutNode) -> NSView {
        switch n {
        case .pane(let gid): return groupView(gid)
        case .split(let vertical, let kids):
            let sv = NSSplitView(); sv.isVertical = vertical; sv.dividerStyle = .thin
            let size = view.bounds.width > 0 ? view.bounds.size : NSSize(width: 1000, height: 700)
            let n = CGFloat(kids.count)
            let child = vertical ? NSSize(width: size.width / n, height: size.height) : NSSize(width: size.width, height: size.height / n)
            sv.frame = NSRect(origin: .zero, size: size)
            for k in kids {   // equal starting frames; NSSplitView keeps proportions from there
                let v = build(k); v.translatesAutoresizingMaskIntoConstraints = true; v.frame = NSRect(origin: .zero, size: child)
                sv.addArrangedSubview(v)
            }
            return sv
        }
    }

    private func groupView(_ gid: String) -> GroupView {
        if let g = groupViews[gid] { g.removeFromSuperview(); return g }
        let g = GroupView(groupId: gid)
        g.strip.onSelect = { [weak self] id in self?.select(id) }
        g.strip.onClose = { [weak self] id in self?.closeTab(id) }
        g.strip.onMenu = { [weak self] id in self?.tabMenu(id) }
        g.strip.addMenu = { [weak self] in self?.newTabMenu(group: gid) ?? NSMenu() }
        g.strip.onDropTab = { [weak self] id, index in self?.layout.move(id, to: gid, index: index); self?.render() }
        g.onDropTab = { [weak self] id, edge in
            guard let self else { return }
            switch edge {
            case nil: layout.move(id, to: gid)
            case .minX?: layout.split(id, from: gid, vertical: true, before: true)
            case .maxX?: layout.split(id, from: gid, vertical: true, before: false)
            case .maxY?: layout.split(id, from: gid, vertical: false, before: true)
            default: layout.split(id, from: gid, vertical: false, before: false)
            }
            render(); focusSelected()
        }
        groupViews[gid] = g
        return g
    }

    /// Strip and visible content of one group (cheap: called on every title / status change).
    private func refreshGroup(_ gid: String) {
        guard let g = groupViews[gid], let model = layout.groups[gid] else { return }
        g.strip.focused = layout.focused == gid || (layout.focused == nil && layout.root?.sessions.first == gid)
        // Only the visible tab is built: a background agent tab must not wake a paused agent.
        let visible = model.selectedTab.flatMap { content($0) }
        g.strip.set(model.tabs.map { t in
            if let c = contents[t.id] { return TabStrip.Item(id: t.id, title: c.title, icon: c.icon, status: c.status, toolTip: c.toolTip) }
            return Self.placeholder(t)
        }, selected: model.selectedTab?.id)
        g.show(visible?.view)
    }

    /// Strip entry for a tab not built yet, from its URI alone.
    static func placeholder(_ t: TabRef) -> TabStrip.Item {
        let body = TabURI.body(t.uri)
        switch TabURI.scheme(t.uri) {
        case "session":
            let s = AppModel.shared.session(body)
            let title = s.map { $0.title.isEmpty ? AgentCatalog.name($0.agent) : $0.title } ?? "Session"
            return .init(id: t.id, title: title, icon: .symbol(AgentCatalog.symbol(s?.agent)), status: s.flatMap { $0.agent == "shell" ? nil : $0.status }, toolTip: title)
        case "file":
            let p = TabURI.filePath(t.uri).path
            return .init(id: t.id, title: (p as NSString).lastPathComponent, icon: NSWorkspace.shared.icon(forFile: p).resized(16), status: nil, toolTip: p)
        case "diff": return .init(id: t.id, title: "Changes", icon: .symbol("plusminus"), status: nil, toolTip: nil)
        case "chat": return .init(id: t.id, title: "Chat", icon: .symbol("bubble.left.and.text.bubble.right"), status: nil, toolTip: nil)
        case "http", "https", "about":
            return .init(id: t.id, title: URL(string: t.uri)?.host ?? "New Page", icon: .symbol("safari"), status: nil, toolTip: t.uri)
        default:
            let v = DeclarativeExtension.viewInfo(t.uri)
            return .init(id: t.id, title: v?.title ?? body, icon: .symbol(v?.icon ?? "puzzlepiece.extension"), status: nil, toolTip: t.uri)
        }
    }

    private func content(_ t: TabRef) -> TabContent? {
        if let c = contents[t.id] { return c }
        let c = ExtensionRegistry.shared.tabProvider(for: t.uri)?.make(t.uri) ?? UnavailableTab(uri: t.uri)
        c.onChange = { [weak self, weak c] in
            guard let self, let gid = layout.group(of: t.id) else { return }
            if let c, c.uri != t.uri, var g = layout.groups[gid], let i = g.tabs.firstIndex(where: { $0.id == t.id }) {
                g.tabs[i].uri = c.uri; layout.groups[gid] = g; scheduleSave()   // e.g. the browser navigated
            }
            refreshGroup(gid)
            AppModel.shared.publishUIState()
        }
        contents[t.id] = c
        return c
    }

    private func showStart() {
        guard start == nil, let w = worktree else { return }
        let s = StartView(worktree: w)
        s.onAgent = { [weak self] agent in self?.newAgent(agent) }
        s.onOpen = { [weak self] uri in self?.open(uri) }
        start = s
        s.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(s)
        NSLayoutConstraint.activate([s.topAnchor.constraint(equalTo: view.topAnchor), s.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     s.leadingAnchor.constraint(equalTo: view.leadingAnchor), s.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        DispatchQueue.main.async { s.focus() }
    }

    // MARK: focus

    private func responderChanged(_ r: NSResponder?) {
        var v = r as? NSView
        while let x = v, !(x is GroupView) { v = x.superview }
        guard let g = v as? GroupView, layout.focused != g.groupId else { publishFocus(); return }
        let old = layout.focused
        layout.focused = g.groupId
        if let old { refreshGroup(old) }
        refreshGroup(g.groupId)
        publishFocus()
    }

    /// The focused tab tells the inspector which agent / file the user is looking at.
    private func publishFocus() {
        let uri = layout.focusedGroup?.selectedTab?.uri ?? ""
        let wb = Workbench.shared
        switch TabURI.scheme(uri) {
        case "session": wb.focusedSession = TabURI.body(uri)
        case "file": wb.focusedFile = TabURI.filePath(uri).path
        default: break
        }
        if wb.focusedSession.flatMap({ AppModel.shared.session($0)?.worktreeId }) != workspaceId {
            wb.focusedSession = AppModel.shared.sessions.last { $0.worktreeId == workspaceId && $0.status != .exited && $0.agent != "shell" }?.id
        }
        AppModel.shared.publishUIState()
    }

    func focusSelected() {
        guard let t = layout.focusedGroup?.selectedTab else { start?.focus(); return }
        DispatchQueue.main.async { [weak self] in self?.contents[t.id]?.focus() }
    }

    // MARK: tabs

    func select(_ tab: String) {
        let old = layout.focused
        layout.select(tab)
        if let old, old != layout.focused { refreshGroup(old) }
        if let gid = layout.group(of: tab) { refreshGroup(gid) }
        focusSelected(); publishFocus(); scheduleSave()
    }

    /// Opens a URI in the focused group (or a new group to the right / below). Reuses a tab already showing it.
    func open(_ uri: String, split: SplitDirection? = nil) {
        switch TabURI.scheme(uri) {
        case "agent":
            let q = URLComponents(string: uri)
            newAgent(q?.path.isEmpty == false ? q?.path : nil, prompt: q?.queryItems?.first { $0.name == "prompt" }?.value, split: split); return
        case "terminal":
            let q = URLComponents(string: uri)
            run(command: q?.queryItems?.first { $0.name == "cmd" }?.value, title: q?.queryItems?.first { $0.name == "title" }?.value, split: split); return
        default: break
        }
        if let t = layout.tab(uri: uri) {   // already open (maybe added by reconcile a moment ago)
            if let split, let gid = layout.group(of: t.id) { layout.split(t.id, from: gid, vertical: split == .right, before: false); render() }
            select(t.id); return
        }
        if TabURI.scheme(uri) != "session", ExtensionRegistry.shared.tabProvider(for: uri) == nil {
            if let u = URL(string: uri), u.scheme?.hasPrefix("http") == true { NSWorkspace.shared.open(u); return }   // browser extension off
        }
        var target: String? = layout.focusedGroup?.id
        if let split, let f = target { target = layout.newGroup(beside: f, vertical: split == .right) }
        let t = layout.add(uri, to: target)
        render()
        select(t.id)
    }

    func closeTab(_ id: String) {
        if let c = contents[id], !c.close() { return }
        contents[id] = nil
        layout.remove(id)
        if layout.allTabs.isEmpty { layout = WorkspaceLayout() }
        render(); focusSelected()
    }

    var focusedContent: TabContent? { layout.focusedGroup?.selectedTab.flatMap { contents[$0.id] } }

    func closeFocusedTab() { if let t = layout.focusedGroup?.selectedTab { closeTab(t.id) } }

    func selectTab(index: Int) {
        guard let g = layout.focusedGroup, g.tabs.indices.contains(index) else { return }
        select(g.tabs[index].id)
    }
    func cycleTab(_ offset: Int) {
        guard let g = layout.focusedGroup, let cur = g.selectedTab, let i = g.tabs.firstIndex(of: cur), !g.tabs.isEmpty else { return }
        select(g.tabs[(i + offset + g.tabs.count) % g.tabs.count].id)
    }
    func focusGroup(_ offset: Int) {
        guard let ids = layout.root?.sessions, let cur = layout.focusedGroup?.id, let i = ids.firstIndex(of: cur), ids.count > 1 else { return }
        let gid = ids[(i + offset + ids.count) % ids.count]
        if let t = layout.groups[gid]?.selectedTab { select(t.id) }
    }
    /// Moves the focused tab into a new group to the right / below.
    func splitFocused(_ dir: SplitDirection) {
        guard let g = layout.focusedGroup, let t = g.selectedTab else { return }
        if g.tabs.count == 1 { newTerminal(split: dir); return }   // nothing to move: open a terminal there, like a terminal app
        layout.split(t.id, from: g.id, vertical: dir == .right, before: false)
        render(); focusSelected()
    }

    private func tabMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        m.add("Split Right") { [weak self] in self?.select(id); self?.splitFocused(.right) }
        m.add("Split Down") { [weak self] in self?.select(id); self?.splitFocused(.down) }
        m.addItem(.separator())
        if let uri = layout.allTabs.first(where: { $0.id == id })?.uri, TabURI.scheme(uri) == "session" {
            let sid = TabURI.body(uri)
            m.add("Rename…") { AgentActions.rename(sid) }
            m.add("Restart") { AgentActions.restart(sid) }
            m.add("Copy Context") { AgentActions.copyContext(sid) }
            m.addItem(.separator())
        }
        m.add("Close Tab") { [weak self] in self?.closeTab(id) }
        m.add("Close Other Tabs") { [weak self] in
            guard let self, let gid = layout.group(of: id) else { return }
            for t in layout.groups[gid]?.tabs ?? [] where t.id != id { closeTab(t.id) }
        }
        return m
    }

    /// "+" menu: agents, terminal, then whatever extensions offer (browser, chat, extension views…).
    func newTabMenu(group: String?) -> NSMenu {
        let m = NSMenu()
        let agents = AgentCatalog.installed(AgentCatalog.all)
        for a in agents {
            m.add(a.name, symbol: AgentCatalog.symbol(a.id)) { [weak self] in
                if let group { self?.layout.focused = group }
                self?.newAgent(a.id)
            }
        }
        if agents.isEmpty { m.addItem(withTitle: "No agent CLIs found", action: nil, keyEquivalent: "").isEnabled = false }
        m.add("Terminal", symbol: "terminal") { [weak self] in if let group { self?.layout.focused = group }; self?.newTerminal() }
        let ctx = IDEContext.current
        let editors = ExtensionRegistry.shared.all.editors
        if !editors.isEmpty { m.addItem(.separator()) }
        for e in editors {
            m.add(e.title, symbol: e.icon) { [weak self] in
                if let group { self?.layout.focused = group }
                e.open(ctx)
            }
        }
        return m
    }

    // MARK: agents & terminals

    func newAgent(_ agent: String? = nil, prompt: String? = nil, extra: [String: JSONValue] = [:], split: SplitDirection? = nil) {
        var p = extra
        p["worktreeId"] = .string(workspaceId)
        p["agent"] = .string(agent ?? AgentCatalog.defaultAgent)
        if let prompt, !prompt.isEmpty { p["prompt"] = .string(prompt) }
        createSession(p, split: split)
    }
    func newTerminal(split: SplitDirection? = nil) { createSession(["worktreeId": .string(workspaceId), "agent": "shell"], split: split) }
    func run(command: String?, title: String? = nil, split: SplitDirection? = nil) {
        guard let command, !command.isEmpty else { newTerminal(split: split); return }
        var p: [String: JSONValue] = ["worktreeId": .string(workspaceId), "command": .string(command)]
        if let title { p["title"] = .string(title) }
        createSession(p, split: split)
    }

    private func createSession(_ p: [String: JSONValue], split: SplitDirection?) {
        Task {
            guard let r = await AppModel.shared.call("session.create", .object(p)), let s = try? r.decode(Session.self) else { return }
            AppModel.shared.upsert(s)
            open(TabURI.session(s.id), split: split)
        }
    }

    /// Daemon state changed: sessions started elsewhere (CLI, agents, fan-out) get a tab; deleted ones go.
    func reconcile() {
        let mine = AppModel.shared.sessions.filter { $0.worktreeId == workspaceId }
        let known = Set(AppModel.shared.sessions.map(\.id))
        var changed = false
        for t in layout.allTabs where TabURI.scheme(t.uri) == "session" {
            let sid = TabURI.body(t.uri)
            let s = AppModel.shared.session(sid)
            // Ended while Krill was closed (or deleted): nothing to show. Ended now: keep it, the tab offers Restart.
            if !known.contains(sid) || (!reconciledOnce && s?.status == .exited) { contents[t.id] = nil; layout.remove(t.id); changed = true }
        }
        if layout.allTabs.isEmpty, layout.root != nil { layout = WorkspaceLayout(); changed = true }
        let shown = Set(layout.allTabs.filter { TabURI.scheme($0.uri) == "session" }.map { TabURI.body($0.uri) })
        for s in mine where s.status != .exited && !shown.contains(s.id) {
            layout.add(TabURI.session(s.id)); changed = true
        }
        reconciledOnce = true
        if changed || (start == nil && layout.allTabs.isEmpty) || view.subviews.isEmpty { render() } else {
            for gid in layout.root?.sessions ?? [] { refreshGroup(gid) }
        }
    }

    /// Restart: the new session takes the old one's tab.
    func replace(session old: String, with new: String) {
        guard let t = layout.tab(uri: TabURI.session(old)), let gid = layout.group(of: t.id), var g = layout.groups[gid],
              let i = g.tabs.firstIndex(of: t) else { open(TabURI.session(new)); return }
        contents[t.id] = nil
        g.tabs[i].uri = TabURI.session(new); layout.groups[gid] = g
        render(); select(t.id)
    }

    func focus(session sid: String) {
        if let t = layout.tab(uri: TabURI.session(sid)) { select(t.id) } else { open(TabURI.session(sid)) }
    }

    // MARK: persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in guard let self else { return }; layout.save(workspaceId) }
        saveWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// Open tabs and focus, for `ui.state`.
    var stateForAgents: JSONValue {
        .obj(["tabs": .array(layout.allTabs.map { t in .obj(["uri": .string(t.uri), "title": .string(contents[t.id]?.title ?? "")]) }),
              "focused": .string(layout.focusedGroup?.selectedTab?.uri ?? "")])
    }
}

/// A tab whose provider is missing (its extension is disabled or uninstalled).
@MainActor
final class UnavailableTab: TabContent {
    let uri: String
    var onChange: (() -> Void)?
    let view: NSView
    var title: String { "Turned Off" }
    var icon: NSImage? { .symbol("questionmark.square.dashed") }
    init(uri: String) {
        self.uri = uri
        let icon = NSImageView(image: .symbol("puzzlepiece.extension")); icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let t = NSTextField(labelWithString: "Extension Turned Off"); t.font = .systemFont(ofSize: 13, weight: .semibold)
        let l = NSTextField(wrappingLabelWithString: "The extension that shows “\(uri)” is turned off or was removed.")
        l.alignment = .center; l.textColor = .secondaryLabelColor
        let b = ClosureButton(title: "Extensions…") { SettingsWindow.show(section: "extensions") }; b.bezelStyle = .push
        let stack = NSStackView(views: [icon, t, l, b]); stack.orientation = .vertical; stack.spacing = 8
        let v = NSView(); stack.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: v.centerXAnchor), stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                     stack.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, constant: -32), l.widthAnchor.constraint(lessThanOrEqualToConstant: 420)])
        view = v
    }
    func focus() {}
}

extension NSMenu {
    /// Closure-backed item (keeps its target alive through representedObject).
    @discardableResult
    func add(_ title: String, symbol: String? = nil, key: String = "", _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let t = ClosureTarget { MainActor.assumeIsolated { action() } }
        let i = addItem(withTitle: title, action: #selector(ClosureTarget.fire), keyEquivalent: key)
        i.target = t; i.representedObject = t
        if let symbol { i.image = .symbol(symbol) }
        return i
    }
}
