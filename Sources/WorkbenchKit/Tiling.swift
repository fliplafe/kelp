import Foundation

extension WorkspaceLayout {
    /// Each of `tabs` in a pane of its own and the other tabs together in one more, side by side: up to three in a row,
    /// more in rows of about equal panes (four make a 2×2 grid). The focused tab keeps the focus.
    public mutating func tile(_ tabs: [String]) {
        let all = allTabs, was = focusedGroup?.selectedTab?.id
        let picked = all.filter { tabs.contains($0.id) }, rest = all.filter { !tabs.contains($0.id) }
        guard !picked.isEmpty else { return }
        var cells = picked.map { GroupModel(tabs: [$0], selected: $0.id) }
        if !rest.isEmpty {
            let shown = rest.first { t in groups.values.contains { $0.selectedTab == t } } ?? rest[0]
            cells.append(GroupModel(tabs: rest, selected: shown.id))
        }
        let rows = (cells.count + 2) / 3
        var next = 0
        let lines: [LayoutNode] = (0..<rows).map { r in
            let n = cells.count / rows + (r < cells.count % rows ? 1 : 0)
            defer { next += n }
            let row = cells[next..<next + n].map { LayoutNode.pane($0.id) }
            return row.count == 1 ? row[0] : .split(vertical: true, children: row)
        }
        groups = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0) })
        root = lines.count == 1 ? lines[0] : .split(vertical: false, children: lines)
        focused = was.flatMap(group(of:)) ?? cells[0].id
    }
}
