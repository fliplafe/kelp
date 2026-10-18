import Foundation
import Core

/// What a tab in a workspace shows. Terminal tabs hold a split tree of sessions.
enum TabKind: Codable, Equatable {
    case terminal(LayoutNode)
    case changes, files, browser, tasks
    case chat(String)

    var isTerminal: Bool { if case .terminal = self { true } else { false } }
}

struct WorkTab: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var kind: TabKind
    var sessions: [String] { if case .terminal(let l) = kind { l.sessions } else { [] } }
}

/// One workspace's tabs, persisted per worktree so a relaunch shows the same arrangement.
@MainActor
final class WorkspaceTabs {
    let worktreeId: String
    private(set) var tabs: [WorkTab] = []
    var selectedId: String?

    init(worktreeId: String) {
        self.worktreeId = worktreeId
        if let d = UserDefaults.standard.data(forKey: "tabs.\(worktreeId)"), let t = try? JSONDecoder().decode([WorkTab].self, from: d) { tabs = t }
        selectedId = UserDefaults.standard.string(forKey: "tabs.sel.\(worktreeId)") ?? tabs.first?.id
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(tabs), forKey: "tabs.\(worktreeId)")
        UserDefaults.standard.set(selectedId, forKey: "tabs.sel.\(worktreeId)")
    }

    var selected: WorkTab? { tabs.first { $0.id == selectedId } ?? tabs.first }

    /// Drop panes whose session is gone; give live sessions that have no pane (made from the CLI, fan-out…) a tab.
    func reconcile(live: [Session]) {
        let alive = Set(live.filter { $0.status != .exited }.map(\.id))
        tabs = tabs.compactMap { t in
            guard case .terminal(var l) = t.kind else { return t }
            for s in l.sessions where !alive.contains(s) { guard let r = l.removing(s) else { return nil }; l = r }
            var t = t; t.kind = .terminal(l); return t
        }
        // A session shown in a split doesn't also get a tab of its own.
        tabs.removeAll { t in t.sessions.count == 1 && tabs.contains { $0.id != t.id && $0.sessions.count > 1 && $0.sessions.contains(t.sessions[0]) } }
        let placed = Set(tabs.flatMap(\.sessions))
        for s in live where alive.contains(s.id) && !placed.contains(s.id) { tabs.append(WorkTab(kind: .terminal(.pane(s.id)))) }
        if selected == nil || !tabs.contains(where: { $0.id == selectedId }) { selectedId = tabs.first?.id }
        save()
    }

    @discardableResult
    func open(_ kind: TabKind) -> WorkTab {
        // Changes, Files, Browser and Issues are one tab each per workspace.
        if [.changes, .files, .browser, .tasks].contains(kind), let t = tabs.first(where: { $0.kind == kind }) {
            selectedId = t.id; save(); return t
        }
        let t = WorkTab(kind: kind); tabs.append(t); selectedId = t.id; save(); return t
    }

    /// Adds a tab without selecting it.
    func add(_ kind: TabKind) { tabs.append(WorkTab(kind: kind)); save() }

    func addSession(_ id: String, splitting tab: String?, vertical: Bool, beside: String?) {
        // The daemon's "new session" event may have given it a tab of its own already.
        if let i = tabs.firstIndex(where: { $0.sessions == [id] }), tabs[i].id != tab { tabs.remove(at: i) }
        if let tab, let i = tabs.firstIndex(where: { $0.id == tab }), case .terminal(let l) = tabs[i].kind {
            tabs[i].kind = .terminal(l.inserting(id, beside: beside ?? l.sessions.last ?? id, vertical: vertical, before: false))
            selectedId = tabs[i].id
        } else {
            let t = WorkTab(kind: .terminal(.pane(id))); tabs.append(t); selectedId = t.id
        }
        save()
    }

    /// Removes a session's pane; a terminal tab with no panes left closes.
    func removeSession(_ id: String) {
        guard let i = tabs.firstIndex(where: { $0.sessions.contains(id) }), case .terminal(let l) = tabs[i].kind else { return }
        if let r = l.removing(id) { tabs[i].kind = .terminal(r) } else { close(tabs[i].id); return }
        save()
    }

    func replaceSession(_ old: String, with new: String) {
        guard let i = tabs.firstIndex(where: { $0.sessions.contains(old) }), case .terminal(let l) = tabs[i].kind else { return }
        tabs[i].kind = .terminal(l.inserting(new, beside: old, vertical: true, before: true).removing(old) ?? .pane(new))
        save()
    }

    func movePane(_ dragged: String, beside target: String, vertical: Bool, before: Bool) {
        guard dragged != target, let i = tabs.firstIndex(where: { $0.sessions.contains(target) }), case .terminal(let l) = tabs[i].kind else { return }
        // From another tab too: take it out there first.
        if let j = tabs.firstIndex(where: { $0.sessions.contains(dragged) }), j != i { removeSession(dragged) }
        guard let k = tabs.firstIndex(where: { $0.sessions.contains(target) }), case .terminal(let cur) = tabs[k].kind else { return }
        let base = cur.removing(dragged) ?? l
        tabs[k].kind = .terminal(base.inserting(dragged, beside: target, vertical: vertical, before: before))
        selectedId = tabs[k].id; save()
    }

    func close(_ id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if selectedId == id { selectedId = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id }
        save()
    }

    func move(from: Int, to: Int) {
        guard tabs.indices.contains(from) else { return }
        let t = tabs.remove(at: from); tabs.insert(t, at: max(0, min(to, tabs.count))); save()
    }

    func select(offset: Int) {
        guard !tabs.isEmpty, let i = tabs.firstIndex(where: { $0.id == selectedId }) else { return }
        selectedId = tabs[(i + offset + tabs.count) % tabs.count].id; save()
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
