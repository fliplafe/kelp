import AppKit
import Core

struct TabState: Codable, Equatable { var id = UUID().uuidString; var root: LayoutNode }

/// Per-worktree tabs + split layouts, persisted so a relaunch shows the same arrangement.
@MainActor
final class WorkspaceState {
    let key: String
    var tabs: [TabState] = []
    var selected = 0
    init(key: String) {
        self.key = key
        if let d = UserDefaults.standard.data(forKey: "layout.\(key)"), let t = try? JSONDecoder().decode([TabState].self, from: d) { tabs = t }
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(tabs), forKey: "layout.\(key)") }

    /// Drop sessions that no longer exist; add live sessions that have no pane yet as new tabs.
    func reconcile(live: [Session]) {
        let alive = Set(live.filter { $0.status != .exited }.map(\.id))
        tabs = tabs.compactMap { t in
            var root: LayoutNode? = t.root
            for s in t.root.sessions where !alive.contains(s) { root = root?.removing(s) }
            return root.map { TabState(id: t.id, root: $0) }
        }
        let placed = Set(tabs.flatMap(\.root.sessions))
        for s in live where alive.contains(s.id) && !placed.contains(s.id) { tabs.append(TabState(root: .pane(s.id))) }
        selected = min(selected, max(0, tabs.count - 1))
        save()
    }

    func tabIndex(of session: String) -> Int? { tabs.firstIndex { $0.root.sessions.contains(session) } }
}

@MainActor
final class WorkspaceViewController: NSViewController, NSTabViewDelegate {
    private let tabView = NSTabView()
    private let placeholder = NSTextField(labelWithString: "Select or create a worktree  (⇧⌘N)")
    private var states: [String: WorkspaceState] = [:]
    private var panes: [String: PaneView] = [:]
    private(set) var currentKey: String?
    private var focused: String?
    private var rebuilding = false

    override func loadView() {
        let v = NSView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.delegate = self
        placeholder.textColor = .secondaryLabelColor; placeholder.alignment = .center
        for s in [tabView, placeholder] as [NSView] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: v.leadingAnchor), tabView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: v.topAnchor), tabView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: v.centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        view = v
        AppModel.shared.onSessionStatus.append { [weak self] s, _ in self?.panes[s.id]?.update(s) }
    }

    var state: WorkspaceState? { currentKey.flatMap { states[$0] } }
    var currentSessionId: String? { focused ?? state?.tabs[safe: state?.selected ?? 0]?.root.sessions.first }

    func show(worktree id: String?) {
        // Panes of other worktrees let go of their sessions (detach), so idle agents there can hibernate.
        for (sid, _) in panes where AppModel.shared.session(sid)?.worktreeId != id { panes[sid] = nil }
        currentKey = id
        guard let id else { tabView.isHidden = true; placeholder.isHidden = false; return }
        let st = states[id] ?? WorkspaceState(key: id)
        states[id] = st
        st.reconcile(live: AppModel.shared.sessions.filter { $0.worktreeId == id })
        rebuild()
    }

    /// Re-sync after daemon changes (new/exited sessions) without losing the layout.
    func refresh() {
        guard let id = currentKey, let st = states[id] else { return }
        let before = st.tabs
        st.reconcile(live: AppModel.shared.sessions.filter { $0.worktreeId == id })
        if st.tabs == before && tabView.numberOfTabViewItems == st.tabs.count { relabel() } else { rebuild() }
    }

    /// Titles change often (status, auto-naming); only touch labels, not views.
    private func relabel() {
        guard let st = state else { return }
        for (i, t) in st.tabs.enumerated() where i < tabView.numberOfTabViewItems {
            let first = t.root.sessions.first.flatMap { AppModel.shared.session($0) }
            let l = (first?.displayTitle ?? "shell") + (t.root.sessions.count > 1 ? "  +\(t.root.sessions.count - 1)" : "")
            if tabView.tabViewItems[i].label != l { tabView.tabViewItems[i].label = l }
        }
    }

    private func pane(_ sid: String) -> PaneView? {
        if let p = panes[sid] { return p }
        guard let s = AppModel.shared.session(sid) else { return nil }
        let p = PaneView(session: s)
        p.onClose = { [weak self] in self?.close(pane: $0.sessionId) }
        p.onRestart = { [weak self] pane in
            Task { @MainActor in
                guard let r = await AppModel.shared.call("session.restart", .obj(["id": .string(pane.sessionId)])), let s = try? r.decode(Session.self) else { return }
                self?.replace(pane.sessionId, with: s)
            }
        }
        p.onFocus = { [weak self] in self?.focused = $0.sessionId }
        p.onDrop = { [weak self] dragged, target, edge in self?.move(dragged, to: target.sessionId, edge: edge) }
        panes[sid] = p
        return p
    }

    private func build(_ n: LayoutNode) -> NSView {
        switch n {
        case .pane(let s): return pane(s) ?? NSView()
        case .split(let vertical, let c):
            let sv = NSSplitView(); sv.isVertical = vertical; sv.dividerStyle = .thin
            c.forEach { sv.addArrangedSubview(build($0)) }
            return sv
        }
    }

    private func rebuild() {
        guard let st = state else { return }
        rebuilding = true; defer { rebuilding = false }
        placeholder.isHidden = !st.tabs.isEmpty; tabView.isHidden = st.tabs.isEmpty
        for item in tabView.tabViewItems { tabView.removeTabViewItem(item) }
        for (i, t) in st.tabs.enumerated() {
            let item = NSTabViewItem(identifier: t.id)
            let first = t.root.sessions.first.flatMap { AppModel.shared.session($0) }
            item.label = (first?.displayTitle ?? "shell") + (t.root.sessions.count > 1 ? "  +\(t.root.sessions.count - 1)" : "")
            _ = i
            item.view = build(t.root)
            tabView.addTabViewItem(item)
        }
        if st.selected < tabView.numberOfTabViewItems { tabView.selectTabViewItem(at: st.selected) }
        for sid in panes.keys where !st.tabs.contains(where: { $0.root.sessions.contains(sid) }) && AppModel.shared.session(sid)?.worktreeId == currentKey { panes[sid] = nil }
        DispatchQueue.main.async { [weak self] in self?.currentSessionId.flatMap { self?.panes[$0]?.focus() } }
    }

    func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        guard !rebuilding, let item, let i = tabView.tabViewItems.firstIndex(of: item) else { return }
        state?.selected = i; state?.save()
    }

    // MARK: actions
    func add(session: Session, newTab: Bool) {
        guard let st = state else { return }
        AppModel.shared.sessions.removeAll { $0.id == session.id }; AppModel.shared.sessions.append(session)
        if newTab || st.tabs.isEmpty { st.tabs.append(TabState(root: .pane(session.id))); st.selected = st.tabs.count - 1 }
        else if let cur = focused, let i = st.tabIndex(of: cur) {
            st.tabs[i].root = st.tabs[i].root.inserting(session.id, beside: cur, vertical: pendingVertical, before: false); st.selected = i
        } else { st.tabs[st.selected].root = st.tabs[st.selected].root.inserting(session.id, beside: st.tabs[st.selected].root.sessions[0], vertical: pendingVertical, before: false) }
        st.save(); focused = session.id; rebuild()
    }
    var pendingVertical = true
    func split(vertical: Bool) -> Bool { pendingVertical = vertical; return state != nil }

    func close(pane sid: String) {
        guard let st = state, let i = st.tabIndex(of: sid) else { return }
        Task { _ = await AppModel.shared.call("session.kill", .obj(["id": .string(sid)])) }
        if let r = st.tabs[i].root.removing(sid) { st.tabs[i].root = r } else { st.tabs.remove(at: i) }
        panes[sid] = nil; st.save(); rebuild()
    }

    /// Swap a pane's session in place (restart keeps the layout).
    func replace(_ old: String, with s: Session) {
        AppModel.shared.sessions.removeAll { $0.id == old || $0.id == s.id }; AppModel.shared.sessions.append(s)
        guard let st = state, let i = st.tabIndex(of: old) else { add(session: s, newTab: true); return }
        st.tabs[i].root = st.tabs[i].root.inserting(s.id, beside: old, vertical: true, before: true).removing(old) ?? .pane(s.id)
        panes[old] = nil; focused = s.id; st.save(); rebuild()
    }

    func move(_ dragged: String, to target: String, edge: PaneView.DropEdge) {
        guard dragged != target, let st = state, let i = st.tabIndex(of: dragged), st.tabs[i].root.sessions.contains(target) else { return }
        guard let rest = st.tabs[i].root.removing(dragged) else { return }
        let vertical = edge == .left || edge == .right
        st.tabs[i].root = rest.inserting(dragged, beside: target, vertical: vertical, before: edge == .left || edge == .top)
        st.save(); rebuild()
    }

    func focusNeighbor(step: Int) {
        guard let st = state, let cur = currentSessionId, let i = st.tabIndex(of: cur), let n = st.tabs[i].root.neighbor(of: cur, step: step) else { return }
        focused = n; panes[n]?.focus()
    }
    func selectTab(_ i: Int) { guard let st = state, i < st.tabs.count else { return }; st.selected = i; tabView.selectTabViewItem(at: i); st.save() }
    func focus(session: String) {
        guard let st = state, let i = st.tabIndexOf(session) else { return }
        selectTab(i); focused = session; panes[session]?.focus()
    }
}

extension WorkspaceState { func tabIndexOf(_ s: String) -> Int? { tabIndex(of: s) } }
extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
