import Foundation

/// Which way an arrow key moves between panes. Window coordinates: y grows upward.
public enum PaneEdge: Sendable { case left, right, down, up }

extension WorkspaceLayout {
    /// The tab `offset` steps from the selected one in the focused group, wrapping around (⌃Tab).
    public func tab(cycling offset: Int) -> String? {
        guard let g = focusedGroup, let cur = g.selectedTab, let i = g.tabs.firstIndex(of: cur), !g.tabs.isEmpty else { return nil }
        return g.tabs[(i + offset % g.tabs.count + g.tabs.count) % g.tabs.count].id
    }

    /// The selected tab of the pane `offset` steps from the focused one, wrapping around; nil with a single pane.
    public func tabInGroup(cycling offset: Int) -> String? {
        guard let ids = root?.sessions, let cur = focusedGroup?.id, let i = ids.firstIndex(of: cur), ids.count > 1 else { return nil }
        return groups[ids[(i + offset % ids.count + ids.count) % ids.count]]?.selectedTab?.id
    }

    /// An open tab on the same file as `uri`, whatever line it was opened at.
    public func fileTab(sameFileAs uri: String) -> TabRef? {
        guard TabURI.scheme(uri) == "file" else { return nil }
        let path = TabURI.filePath(uri).path
        return allTabs.first { TabURI.scheme($0.uri) == "file" && TabURI.filePath($0.uri).path == path }
    }

    /// The pane on that side of `from`, the nearest by center (Ghostty's goto_split). Panes only touching the edge by
    /// 2 points or less still count as beside it.
    public static func nearestPane(from a: CGRect, among panes: [String: CGRect], toward edge: PaneEdge) -> String? {
        panes.compactMap { id, b -> (String, CGFloat)? in
            let beyond = switch edge {
            case .left: b.maxX <= a.minX + 2
            case .right: b.minX >= a.maxX - 2
            case .down: b.maxY <= a.minY + 2
            case .up: b.minY >= a.maxY - 2
            }
            return beyond ? (id, hypot(b.midX - a.midX, b.midY - a.midY)) : nil
        }.min { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }?.0
    }
}
