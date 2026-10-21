import AppKit
import Core
import WorkbenchKit

/// Opening, selecting, cycling, splitting and closing tabs.
extension EditorArea {
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
            if let name = q?.queryItems?.first(where: { $0.name == "tmux" })?.value { newTmux(name, split: split); return }
            run(command: q?.queryItems?.first { $0.name == "cmd" }?.value, title: q?.queryItems?.first { $0.name == "title" }?.value, split: split); return
        default: break
        }
        // A file already open (at another line): that tab, moved to the line asked for.
        if layout.tab(uri: uri) == nil, let t = layout.fileTab(sameFileAs: uri) {
            select(t.id, focus: focus)
            if let l = TabURI.filePath(uri).line { contents[t.id]?.goTo(line: l) }
            return
        }
        if let t = layout.tab(uri: uri) {   // already open (maybe added by reconcile a moment ago)
            if let split, let gid = layout.group(of: t.id) { layout.split(t.id, from: gid, vertical: split == .right, before: false); arrange(); render() }
            select(t.id, focus: focus); return
        }
        if TabURI.scheme(uri) != "session", ExtensionRegistry.shared.tabProvider(for: uri) == nil {
            if let u = URL(string: uri), u.scheme?.hasPrefix("http") == true { NSWorkspace.shared.open(u); return }   // browser extension off
        }
        var target: String? = layout.focusedGroup?.id
        if let split, let f = target { target = layout.newGroup(beside: f, vertical: split == .right); zoomed = nil }
        let t = layout.add(uri, to: target)
        arrange(); render()
        select(t.id, focus: focus)
    }

    func closeTab(_ id: String) { Task { await closeTabAsking(id) } }

    /// Closes the tab once it agrees (its questions are sheets, awaited); false when it stays.
    @discardableResult
    func closeTabAsking(_ id: String) async -> Bool {
        guard closing.insert(id).inserted else { return false }
        defer { closing.remove(id) }
        let uri = layout.allTabs.first { $0.id == id }?.uri ?? ""
        let sid = TabURI.scheme(uri) == "session" ? TabURI.body(uri) : nil
        // A tab not built yet (in the background since launch) ends its session all the same.
        if let c = contents[id] { guard await c.close() else { return false } } else if let sid, await !SessionTab.close(session: sid) { return false }
        guard layout.allTabs.contains(where: { $0.id == id }) else { return true }   // gone while it asked (its workspace closed)
        if let sid { closed.insert(sid) }
        contents[id] = nil
        layout.remove(id)
        if layout.allTabs.isEmpty { let manual = layout.manual; layout = WorkspaceLayout(); layout.manual = manual }
        arrange(); render(); focusSelected()
        return true
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
    func cycleTab(_ offset: Int) { if let id = layout.tab(cycling: offset) { select(id) } }
    /// ⇧⌘↩: the focused group fills the editor area, or every pane comes back (like zooming a split in Terminal or Ghostty).
    func toggleZoom() {
        guard let g = layout.focusedGroup, (layout.root?.sessions.count ?? 0) > 1 else { NSSound.beep(); return }
        zoomed = zoomed == nil ? g.id : nil
        render(); focusSelected()
    }

    func focusGroup(_ offset: Int) {
        zoomed = nil
        if let id = layout.tabInGroup(cycling: offset) { select(id) }
    }
    /// ⌥⌘ arrows: the pane on that side of the focused one, the nearest by center (Ghostty's goto_split).
    func focusGroup(toward edge: NSRectEdge) {
        guard let cur = layout.focusedGroup?.id, let from = groupViews[cur], from.window != nil else { return }
        var others: [String: CGRect] = [:]
        for (id, v) in groupViews where id != cur && v.window != nil { others[id] = v.convert(v.bounds, to: nil) }
        guard let gid = WorkspaceLayout.nearestPane(from: from.convert(from.bounds, to: nil), among: others, toward: edge),
              let t = layout.groups[gid]?.selectedTab else { NSSound.beep(); return }
        select(t.id)
    }

    /// Moves the focused tab into a new group to the right / below.
    func splitFocused(_ dir: SplitDirection) {
        zoomed = nil
        arrangedByHand()
        guard let g = layout.focusedGroup, let t = g.selectedTab else { return }
        if g.tabs.count == 1 { newTerminal(split: dir); return }   // nothing to move: open a terminal there, like a terminal app
        layout.split(t.id, from: g.id, vertical: dir == .right, before: false)
        render(); focusSelected()
    }

    /// Agents side by side, the default: each running agent in a pane of its own; terminals, commands, files and paused
    /// or ended agents share one more (a paused agent shown would wake). Done as tabs come and go; true if panes moved.
    @discardableResult
    func arrange() -> Bool {
        guard layout.manual != true else { return false }
        let agents = layout.allTabs.filter { t in
            guard TabURI.scheme(t.uri) == "session", let s = AppModel.shared.session(TabURI.body(t.uri)) else { return false }
            return !["shell", "custom"].contains(s.agent) && s.status != .exited && s.status != .hibernated
        }
        let old = layout
        layout.tile(agents.map(\.id))
        return layout != old
    }

    /// The title bar's button and ⌃⌘T: agents side by side, or every tab back in one pane, arranged by hand from then on.
    func toggleSideBySide() {
        zoomed = nil
        layout.manual = layout.manual == true ? nil : true
        if layout.manual == true { layout.tile([]) } else { arrange() }
        render(); focusSelected(); publishFocus()
    }

    /// A split or a tab dragged to another pane: the panes stay as the user puts them, agents no longer tile.
    func arrangedByHand() {
        guard layout.manual != true else { return }
        layout.manual = true; publishFocus()
    }

    func tabMenu(_ id: String) -> NSMenu {
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
            let others = (layout.groups[gid]?.tabs ?? []).filter { $0.id != id }
            Task { for t in others { await self.closeTabAsking(t.id) } }   // one question at a time
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
        if AgentCatalog.hasTmux(AppModel.shared.worktree(workspaceId)) {
            m.add(String(localized: "tmux Session…"), symbol: "rectangle.split.3x1") { [weak self] in
                if let group { self?.layout.focused = group }
                QuickOpen.shared.showTmux()
            }
        }
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

}
