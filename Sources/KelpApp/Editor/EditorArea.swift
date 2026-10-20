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
    /// The group shown alone (⇧⌘↩), not saved: a relaunch shows every pane.
    private var zoomed: String?

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
        track { FileIcon.revision } changed: { [weak self] _ in self?.groupViews.keys.forEach { self?.refreshGroup($0) } }
        // The empty workspace lists the agents that work, with their icons; rebuild it when either changes.
        track { AgentAvailability.shared.ids } changed: { [weak self] _ in self?.rebuildStart() }
        track { AgentIcons.shared.images.count } changed: { [weak self] _ in
            self?.rebuildStart()
            for gid in self?.layout.root?.sessions ?? [] { self?.refreshGroup(gid) }   // agent tabs get the real icon
        }
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
        guard var root = layout.root, !layout.allTabs.isEmpty else { showStart(); return }
        start = nil
        if let z = zoomed, layout.groups[z] != nil, root.sessions.count > 1 { root = .pane(z) } else { zoomed = nil }
        if zoomed == nil, let sizes = layout.sizes { layout.sizes = sizes.filter { root.splitKeys.contains($0.key) } }
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
            let sv = EqualizingSplitView(); sv.isVertical = vertical; sv.dividerStyle = .thin
            let key = LayoutNode.splitKey(kids)
            sv.identifier = NSUserInterfaceItemIdentifier(key); sv.delegate = self
            let size = view.bounds.width > 0 ? view.bounds.size : NSSize(width: 1000, height: 700)
            let saved = layout.sizes?[key].flatMap { $0.count == kids.count ? $0 : nil }
            let shares = saved ?? Array(repeating: 1 / Double(kids.count), count: kids.count)
            sv.frame = NSRect(origin: .zero, size: size)
            for (k, share) in zip(kids, shares) {   // starting frames; NSSplitView keeps proportions from there
                let v = build(k); v.translatesAutoresizingMaskIntoConstraints = true
                v.frame.size = vertical ? NSSize(width: size.width * share, height: size.height) : NSSize(width: size.width, height: size.height * share)
                sv.addArrangedSubview(v)
            }
            return sv
        }
    }

    /// Where a tab dropped at the editor area's outer edge will go: half of the whole area along that side.
    private let outerHint: NSView = {
        let v = NSView(); v.wantsLayer = true; v.isHidden = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor; v.layer?.borderWidth = 1; v.layer?.cornerRadius = 6
        return v
    }()
    private func showOuterHint(_ edge: NSRectEdge?) {
        guard let edge else { outerHint.isHidden = true; return }
        if outerHint.superview !== view { view.addSubview(outerHint, positioned: .above, relativeTo: nil) }
        var r = view.bounds.insetBy(dx: 6, dy: 6)
        // Its share once added: one more beside the panes already split that way.
        let vertical = edge == .minX || edge == .maxX
        let n: CGFloat = { if case .split(let v, let c)? = layout.root, v == vertical { CGFloat(c.count + 1) } else { 2 } }()
        switch edge {
        case .minX: r.size.width /= n
        case .maxX: r.origin.x += r.width * (n - 1) / n; r.size.width /= n
        case .minY: r.size.height /= n
        default: r.origin.y += r.height * (n - 1) / n; r.size.height /= n
        }
        outerHint.frame = r; outerHint.isHidden = false
    }

    /// View › Equalize Panes: every split back to equal shares.
    func equalizePanes() {
        guard layout.sizes != nil else { return }
        layout.sizes = nil; render(); focusSelected()
    }

    private func groupView(_ gid: String) -> GroupView {
        if let g = groupViews[gid] { g.removeFromSuperview(); return g }
        let g = GroupView(groupId: gid)
        g.strip.onSelect = { [weak self] id in self?.select(id) }
        g.strip.onClose = { [weak self] id in self?.closeTab(id) }
        g.strip.onMenu = { [weak self] id in self?.tabMenu(id) }
        g.strip.addMenu = { [weak self] in self?.newTabMenu(group: gid) ?? NSMenu() }
        g.strip.onUnzoom = { [weak self] in self?.toggleZoom() }
        g.strip.onDropTab = { [weak self] id, index in self?.layout.move(id, to: gid, index: index); self?.render() }
        g.editorFrame = { [weak self] in self.map { $0.view.convert($0.view.bounds, to: nil) } }
        g.showOuterHint = { [weak self] edge in self?.showOuterHint(edge) }
        g.onDropOuter = { [weak self] id, edge in
            guard let self else { return }
            layout.splitRoot(id, vertical: edge == .minX || edge == .maxX, before: edge == .minX || edge == .maxY)
            render(); focusSelected()
        }
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
        g.strip.zoomed = zoomed == gid
        // Only the visible tab is built: a background agent tab must not wake a paused agent.
        let visible = model.selectedTab.flatMap { content($0) }
        g.strip.set(Self.disambiguated(model.tabs.map { t in
            if let c = contents[t.id] {
                return TabStrip.Item(id: t.id, title: c.title, icon: c.icon, status: c.status, unread: c.unread, toolTip: c.toolTip, edited: c.isEdited, meter: c.meter)
            }
            return Self.placeholder(t)
        }, model.tabs), selected: model.selectedTab?.id)
        g.show(visible?.view)
        // Like Ghostty's unfocused splits: with panes side by side, a terminal without focus fades a little.
        g.dimmed = !g.strip.focused && zoomed == nil && (layout.root?.sessions.count ?? 0) > 1 && visible is SessionTab
        g.attention = (visible as? SessionTab)?.attention
        showEdited()
    }

    /// Unsaved files: the dot in the window's close button (and on their tabs), as in any Mac document app.
    func showEdited() { view.window?.isDocumentEdited = !editedFiles.isEmpty }

    /// Files with unsaved changes in this workspace (asked about on quit; the workspace isn't dropped from memory).
    var editedFiles: [SavableTab] { contents.values.compactMap { $0 as? SavableTab }.filter(\.isEdited) }

    /// Strip entry for a tab not built yet, from its URI alone.
    /// Two files with one name (README.md twice): each tab adds its folder, "README.md — docs", as Xcode does.
    static func disambiguated(_ items: [TabStrip.Item], _ tabs: [TabRef]) -> [TabStrip.Item] {
        let paths = tabs.map { TabURI.scheme($0.uri) == "file" ? TabURI.filePath($0.uri).path as NSString : nil }
        let names = paths.map { $0?.lastPathComponent }
        return zip(items, paths).map { item, path in
            guard let path, names.filter({ $0 == path.lastPathComponent }).count > 1 else { return item }
            var item = item
            item.title = path.lastPathComponent + " — " + (path.deletingLastPathComponent as NSString).lastPathComponent
            return item
        }
    }

    static func placeholder(_ t: TabRef) -> TabStrip.Item {
        let body = TabURI.body(t.uri)
        switch TabURI.scheme(t.uri) {
        case "session":
            let s = AppModel.shared.session(body)
            let title = s.map(AgentCatalog.displayName) ?? String(localized: "Session")
            return .init(id: t.id, title: title, icon: AgentCatalog.icon(s?.agent), status: s.flatMap { $0.agent == "shell" ? nil : $0.endedWithError ? .error : $0.status },
                         unread: s?.unread ?? false, toolTip: title)
        case "file":
            let p = TabURI.filePath(t.uri).path
            return .init(id: t.id, title: (p as NSString).lastPathComponent, icon: FileIcon.image((p as NSString).lastPathComponent), status: nil, toolTip: p)
        case "diff": return .init(id: t.id, title: String(localized: "Changes"), icon: .symbol("plusminus"), status: nil, toolTip: nil)
        case "http", "https", "about":
            return .init(id: t.id, title: URL(string: t.uri)?.host ?? String(localized: "New Page"), icon: .symbol("safari"), status: nil, toolTip: t.uri)
        case "preview": return .init(id: t.id, title: (body as NSString).lastPathComponent, icon: .symbol("eye"), status: nil, toolTip: body)
        case "usage": return .init(id: t.id, title: "Usage", icon: .symbol("chart.bar"), status: nil, toolTip: nil)
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

    private func rebuildStart() {
        guard start != nil else { return }
        start?.removeFromSuperview(); start = nil; showStart()
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

    /// `focus: false` shows the tab but leaves the keys where they are (a click in the Files tree).
    func select(_ tab: String, focus: Bool = true) {
        let old = layout.focused
        layout.select(tab)
        if let old, old != layout.focused { refreshGroup(old) }
        if let gid = layout.group(of: tab) { refreshGroup(gid) }
        if focus { focusSelected() }
        publishFocus(); scheduleSave()
    }

    /// Opens a URI in the focused group (or a new group to the right / below). Reuses a tab already showing it.
    func open(_ uri: String, split: SplitDirection? = nil, focus: Bool = true) {
        switch TabURI.scheme(uri) {
        case "agent":
            let q = URLComponents(string: uri)
            newAgent(q?.path.isEmpty == false ? q?.path : nil, prompt: q?.queryItems?.first { $0.name == "prompt" }?.value, split: split); return
        case "terminal":
            let q = URLComponents(string: uri)
            run(command: q?.queryItems?.first { $0.name == "cmd" }?.value, title: q?.queryItems?.first { $0.name == "title" }?.value, split: split); return
        default: break
        }
        // A file already open (at another line): that tab, moved to the line asked for.
        if TabURI.scheme(uri) == "file", layout.tab(uri: uri) == nil,
           let t = layout.allTabs.first(where: { TabURI.scheme($0.uri) == "file" && TabURI.filePath($0.uri).path == TabURI.filePath(uri).path }) {
            select(t.id, focus: focus)
            if let l = uri.split(separator: "#").last.flatMap({ $0.hasPrefix("L") ? Int($0.dropFirst()) : nil }) { (contents[t.id] as? FileTab)?.goTo(line: l) }
            return
        }
        if let t = layout.tab(uri: uri) {   // already open (maybe added by reconcile a moment ago)
            if let split, let gid = layout.group(of: t.id) { layout.split(t.id, from: gid, vertical: split == .right, before: false); render() }
            select(t.id, focus: focus); return
        }
        if TabURI.scheme(uri) != "session", ExtensionRegistry.shared.tabProvider(for: uri) == nil {
            if let u = URL(string: uri), u.scheme?.hasPrefix("http") == true { NSWorkspace.shared.open(u); return }   // browser extension off
        }
        var target: String? = layout.focusedGroup?.id
        if let split, let f = target { target = layout.newGroup(beside: f, vertical: split == .right); zoomed = nil }
        let t = layout.add(uri, to: target)
        render()
        select(t.id, focus: focus)
    }

    func closeTab(_ id: String) {
        if let c = contents[id], !c.close() { return }
        contents[id] = nil
        layout.remove(id)
        if layout.allTabs.isEmpty { layout = WorkspaceLayout() }
        render(); focusSelected()
    }

    /// Sessions whose tab is on screen right now (the selected tab of each pane shown).
    var visibleSessions: [String] {
        let groups = zoomed.map { [$0] } ?? layout.root?.sessions ?? []
        return groups.compactMap { layout.groups[$0]?.selectedTab?.uri }.filter { TabURI.scheme($0) == "session" }.map(TabURI.body)
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
    /// ⇧⌘↩: the focused group fills the editor area, or every pane comes back (like zooming a split in Terminal or Ghostty).
    func toggleZoom() {
        guard let g = layout.focusedGroup, (layout.root?.sessions.count ?? 0) > 1 else { NSSound.beep(); return }
        zoomed = zoomed == nil ? g.id : nil
        render(); focusSelected()
    }

    func focusGroup(_ offset: Int) {
        zoomed = nil
        guard let ids = layout.root?.sessions, let cur = layout.focusedGroup?.id, let i = ids.firstIndex(of: cur), ids.count > 1 else { return }
        let gid = ids[(i + offset + ids.count) % ids.count]
        if let t = layout.groups[gid]?.selectedTab { select(t.id) }
    }
    /// ⌥⌘ arrows: the pane on that side of the focused one, the nearest by center (Ghostty's goto_split).
    func focusGroup(toward edge: NSRectEdge) {
        guard let cur = layout.focusedGroup?.id, let from = groupViews[cur], from.window != nil else { return }
        let a = from.convert(from.bounds, to: nil)
        let near = groupViews.compactMap { id, v -> (String, CGFloat)? in
            guard id != cur, v.window != nil else { return nil }
            let b = v.convert(v.bounds, to: nil)
            let beyond = switch edge {   // window coordinates: y grows upward
            case .minX: b.maxX <= a.minX + 2
            case .maxX: b.minX >= a.maxX - 2
            case .minY: b.maxY <= a.minY + 2
            default: b.minY >= a.maxY - 2
            }
            return beyond ? (id, hypot(b.midX - a.midX, b.midY - a.midY)) : nil
        }.min { $0.1 < $1.1 }
        guard let gid = near?.0, let t = layout.groups[gid]?.selectedTab else { NSSound.beep(); return }
        select(t.id)
    }

    /// Moves the focused tab into a new group to the right / below.
    func splitFocused(_ dir: SplitDirection) {
        zoomed = nil
        guard let g = layout.focusedGroup, let t = g.selectedTab else { return }
        if g.tabs.count == 1 { newTerminal(split: dir); return }   // nothing to move: open a terminal there, like a terminal app
        layout.split(t.id, from: g.id, vertical: dir == .right, before: false)
        render(); focusSelected()
    }

    private func tabMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        m.add(String(localized: "Split Right")) { [weak self] in self?.select(id); self?.splitFocused(.right) }
        m.add(String(localized: "Split Down")) { [weak self] in self?.select(id); self?.splitFocused(.down) }
        m.addItem(.separator())
        if let uri = layout.allTabs.first(where: { $0.id == id })?.uri, TabURI.scheme(uri) == "session" {
            let sid = TabURI.body(uri)
            m.add(String(localized: "Rename…")) { AgentActions.rename(sid) }
            m.add(String(localized: "Restart")) { AgentActions.restart(sid) }
            m.add(String(localized: "Copy Context")) { AgentActions.copyContext(sid) }
            m.setSubmenu(AgentActions.handoffMenu(sid), for: m.addItem(withTitle: String(localized: "Hand Off to"), action: nil, keyEquivalent: ""))
            m.add(String(localized: "Changes in Its Last Turn")) { [weak self] in
                guard let self else { return }
                Workbench.shared.focusedSession = sid
                open(DiffTab.uri(workspaceId, source: "turn"), split: .right)
            }
            m.addItem(.separator())
        }
        if let uri = layout.allTabs.first(where: { $0.id == id })?.uri, TabURI.scheme(uri) == "file" {
            let path = TabURI.filePath(uri).path
            m.add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            m.add(String(localized: "Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
            m.add(String(localized: "Copy Web Link")) { FileActions.copyWebLink(path) }
            m.add(String(localized: "Send to Agent")) { FileActions.sendToAgent(path) }
            if ["html", "htm"].contains((path as NSString).pathExtension.lowercased()) {
                m.add(String(localized: "Open Preview to the Side")) { [weak self] in self?.open("preview:" + path, split: .right) }
            }
            m.addItem(.separator())
        }
        m.add(String(localized: "Close Tab")) { [weak self] in self?.closeTab(id) }
        m.add(String(localized: "Close Other Tabs")) { [weak self] in
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
            let item = m.add(a.name) { [weak self] in
                if let group { self?.layout.focused = group }
                self?.newAgent(a.id)
            }
            item.image = AgentCatalog.icon(a.id)
        }
        if agents.isEmpty { m.addItem(withTitle: String(localized: "No agent CLIs found"), action: nil, keyEquivalent: "").isEnabled = false }
        m.add(String(localized: "Terminal"), symbol: "terminal") { [weak self] in if let group { self?.layout.focused = group }; self?.newTerminal() }
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
        var p = p
        if let (cols, rows) = terminalSize(split: split) { p["cols"] = .int(cols); p["rows"] = .int(rows) }
        Task {
            guard let r = await AppModel.shared.call("session.create", .object(p)), let s = try? r.decode(Session.self) else { return }
            AppModel.shared.upsert(s)
            open(TabURI.session(s.id), split: split)
        }
    }

    /// The size the new terminal will have, so the shell's first screen isn't drawn for another width (zsh's stray "%"
    /// line, an agent's banner wrapped twice). A split gets half; a guess on the small side only leaves room.
    private func terminalSize(split: SplitDirection?) -> (Int, Int)? {
        let shown = contents.values.compactMap { ($0 as? SessionTab)?.pane }.filter { $0.window != nil }
        guard let g = ((focusedContent as? SessionTab)?.pane ?? shown.first)?.gridSize ?? PaneView.lastGrid else { return nil }
        switch split {
        case .right?: return (max(20, g.cols / 2 - 1), g.rows)
        case .down?: return (g.cols, max(5, g.rows / 2 - 1))
        case nil: return (g.cols, g.rows)
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
            // Ended while Kelp was closed (or deleted): nothing to show. Ended now: keep it, the tab offers Restart.
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
    func replace(session old: String, with new: String) { replace(TabURI.session(old), with: TabURI.session(new)) }

    /// `new` in the tab that showed `old`, in its place (a restarted session, a new file saved under a name).
    func replace(_ old: String, with new: String) {
        guard let t = layout.tab(uri: old), let gid = layout.group(of: t.id), var g = layout.groups[gid],
              let i = g.tabs.firstIndex(of: t) else { open(new); return }
        contents[t.id] = nil
        g.tabs[i].uri = new; layout.groups[gid] = g
        render(); select(t.id)
    }

    func focus(session sid: String) {
        if let t = layout.tab(uri: TabURI.session(sid)) { select(t.id) } else { open(TabURI.session(sid)) }
    }

    // MARK: persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            layout.save(workspaceId)
        }
        saveWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// Every open tab (URI and title), for the palette.
    var openTabs: [(String, String)] { layout.allTabs.map { ($0.uri, contents[$0.id]?.title ?? Self.placeholder($0).title) } }

    /// Open tabs and focus, for `ui.state`.
    var stateForAgents: JSONValue {
        .obj(["tabs": .array(layout.allTabs.map { t in .obj(["uri": .string(t.uri), "title": .string(contents[t.id]?.title ?? "")]) }),
              "focused": .string(layout.focusedGroup?.selectedTab?.uri ?? "")])
    }
}

extension EditorArea: NSSplitViewDelegate {
    /// A dragged divider stays where it was put: tab changes and relaunches rebuild the splits from these shares.
    func splitViewDidResizeSubviews(_ n: Notification) {
        guard let sv = n.object as? NSSplitView, sv.window != nil, let key = sv.identifier?.rawValue,
              sv.arrangedSubviews.count == key.split(separator: ",").count else { return }   // being taken apart: not the user
        let lengths = sv.arrangedSubviews.map { Double(sv.isVertical ? $0.frame.width : $0.frame.height) }
        let total = lengths.reduce(0, +)
        guard total > 20 else { return }
        let shares = lengths.map { $0 / total }
        if layout.sizes?[key].map({ zip($0, shares).allSatisfy { abs($0 - $1) < 0.002 } }) == true { return }
        layout.sizes = (layout.sizes ?? [:]).merging([key: shares]) { $1 }
        scheduleSave()
    }
}

/// A tab whose provider is missing (its extension is disabled or uninstalled).
@MainActor
final class UnavailableTab: TabContent {
    let uri: String
    var onChange: (() -> Void)?
    let view: NSView
    var title: String { String(localized: "Turned Off") }
    var icon: NSImage? { .symbol("questionmark.square.dashed") }
    init(uri: String) {
        self.uri = uri
        let icon = NSImageView(image: .symbol("puzzlepiece.extension")); icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let t = NSTextField(labelWithString: String(localized: "Extension Turned Off")); t.font = .systemFont(ofSize: 13, weight: .semibold)
        let l = NSTextField(wrappingLabelWithString: String(localized: "The extension that shows “\(uri)” is turned off or was removed."))
        l.alignment = .center; l.textColor = .secondaryLabelColor
        let b = ClosureButton(title: String(localized: "Extensions…")) { SettingsWindow.show(section: "extensions") }; b.bezelStyle = .push
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

/// A double-click on a divider shares that split equally (like Terminal's and Ghostty's splits).
final class EqualizingSplitView: NSSplitView {
    override func mouseDown(with e: NSEvent) {
        guard e.clickCount == 2, arrangedSubviews.count > 1 else { return super.mouseDown(with: e) }
        let p = convert(e.locationInWindow, from: nil)
        let onDivider = arrangedSubviews.dropLast().contains { v in
            let f = v.frame
            return isVertical ? abs(p.x - f.maxX) <= dividerThickness + 3 : abs(p.y - f.maxY) <= dividerThickness + 3
        }
        guard onDivider else { return super.mouseDown(with: e) }
        let total = (isVertical ? bounds.width : bounds.height) - dividerThickness * CGFloat(arrangedSubviews.count - 1)
        let share = total / CGFloat(arrangedSubviews.count)
        for i in 0..<(arrangedSubviews.count - 1) { setPosition(share * CGFloat(i + 1) + dividerThickness * CGFloat(i), ofDividerAt: i) }
    }
}
