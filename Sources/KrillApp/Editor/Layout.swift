import Foundation
import Core

struct TabRef: Codable, Hashable {
    var id = UUID().uuidString
    var uri: String
}

struct GroupModel: Codable, Equatable {
    var id = UUID().uuidString
    var tabs: [TabRef] = []
    var selected: String?
    var selectedTab: TabRef? { tabs.first { $0.id == selected } ?? tabs.first }
}

/// One workspace's editor area: groups of tabs arranged by a split tree (LayoutNode panes are group ids).
/// Persisted per workspace so a relaunch shows the same arrangement.
struct WorkspaceLayout: Codable, Equatable {
    var root: LayoutNode?
    var groups: [String: GroupModel] = [:]
    var focused: String?

    var allTabs: [TabRef] { (root?.sessions ?? []).compactMap { groups[$0] }.flatMap(\.tabs) }
    var focusedGroup: GroupModel? { focused.flatMap { groups[$0] } ?? root?.sessions.first.flatMap { groups[$0] } }
    func group(of tab: String) -> String? { groups.first { $0.value.tabs.contains { $0.id == tab } }?.key }
    func tab(uri: String) -> TabRef? { allTabs.first { $0.uri == uri } }

    static func load(_ workspace: String) -> WorkspaceLayout {
        guard let d = UserDefaults.standard.data(forKey: "layout3.\(workspace)"), let l = try? JSONDecoder().decode(WorkspaceLayout.self, from: d) else { return WorkspaceLayout() }
        return l
    }
    func save(_ workspace: String) { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "layout3.\(workspace)") }

    /// Adds a tab to `group` (or the focused group, or a new one) and selects it.
    @discardableResult
    mutating func add(_ uri: String, to group: String? = nil, at index: Int? = nil) -> TabRef {
        let t = TabRef(uri: uri)
        let gid = group ?? focusedGroup?.id ?? newGroup(beside: nil, vertical: true)
        guard var g = groups[gid] else { return t }
        g.tabs.insert(t, at: min(index ?? g.tabs.count, g.tabs.count)); g.selected = t.id
        groups[gid] = g; focused = gid
        return t
    }

    /// A new empty group next to `beside` (the right / below), or the first one.
    @discardableResult
    mutating func newGroup(beside: String?, vertical: Bool, before: Bool = false) -> String {
        let g = GroupModel()
        groups[g.id] = g
        if let beside, let r = root { root = r.inserting(g.id, beside: beside, vertical: vertical, before: before) } else if let r = root {
            root = r.inserting(g.id, beside: r.sessions.last ?? g.id, vertical: vertical, before: false)
        } else { root = .pane(g.id) }
        focused = g.id
        return g.id
    }

    mutating func select(_ tab: String) {
        guard let gid = group(of: tab) else { return }
        groups[gid]?.selected = tab; focused = gid
    }

    /// Removes a tab; an emptied group disappears unless it's the last one.
    mutating func remove(_ tab: String) {
        guard let gid = group(of: tab), var g = groups[gid], let i = g.tabs.firstIndex(where: { $0.id == tab }) else { return }
        g.tabs.remove(at: i)
        if g.selected == tab { g.selected = g.tabs.isEmpty ? nil : g.tabs[min(i, g.tabs.count - 1)].id }
        groups[gid] = g
        if g.tabs.isEmpty, (root?.sessions.count ?? 0) > 1 { dropGroup(gid) }
    }

    mutating func dropGroup(_ gid: String) {
        groups[gid] = nil
        root = root?.removing(gid)
        if focused == gid { focused = root?.sessions.first }
    }

    /// Moves a tab into another group (index nil = end), or into a new group split off `target` (edge).
    mutating func move(_ tab: String, to target: String, index: Int? = nil) {
        guard let from = group(of: tab), let t = groups[from]?.tabs.first(where: { $0.id == tab }) else { return }
        if from == target, var g = groups[from], let i = g.tabs.firstIndex(of: t) {
            g.tabs.remove(at: i); g.tabs.insert(t, at: min(index ?? g.tabs.count, g.tabs.count)); g.selected = t.id
            groups[from] = g; focused = from; return
        }
        remove(tab)
        guard var g = groups[target] else { return }
        g.tabs.insert(t, at: min(index ?? g.tabs.count, g.tabs.count)); g.selected = t.id
        groups[target] = g; focused = target
    }

    mutating func split(_ tab: String, from target: String, vertical: Bool, before: Bool) {
        guard let t = allTabs.first(where: { $0.id == tab }) else { return }
        let alone = group(of: tab) == target && groups[target]?.tabs.count == 1
        guard !alone else { return }   // splitting a group off itself with its only tab changes nothing
        remove(tab)
        let gid = newGroup(beside: groups[target] == nil ? nil : target, vertical: vertical, before: before)
        groups[gid]?.tabs = [t]; groups[gid]?.selected = t.id
    }
}
