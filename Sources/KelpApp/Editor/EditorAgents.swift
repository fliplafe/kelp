import AppKit
import Core
import WorkbenchKit

/// Starting agents and terminals in the focused pane, and reacting to their sessions.
extension EditorArea {
    func newAgent(_ agent: String? = nil, prompt: String? = nil, extra: [String: JSONValue] = [:], split: SplitDirection? = nil) {
        var p = extra
        p["worktreeId"] = .string(workspaceId)
        p["agent"] = .string(agent ?? AgentCatalog.defaultAgent)
        if let prompt, !prompt.isEmpty { p["prompt"] = .string(prompt) }
        createSession(p, split: split)
    }
    func newTerminal(split: SplitDirection? = nil) { createSession(["worktreeId": .string(workspaceId), "agent": "shell"], split: split) }
    /// `cwd`: run it in another folder (a remote project's runs on its host), as a tab here.
    func run(command: String?, title: String? = nil, cwd: String? = nil, split: SplitDirection? = nil) {
        guard let command, !command.isEmpty else { newTerminal(split: split); return }
        var p: [String: JSONValue] = ["worktreeId": .string(workspaceId), "command": .string(command)]
        if let title { p["title"] = .string(title) }
        if let cwd { p["cwd"] = .string(cwd) }
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

    /// Daemon state changed: sessions started elsewhere (CLI, agents, scripts) get a tab; deleted ones go.
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
        closed = closed.filter { AppModel.shared.session($0).map { $0.status != .exited } ?? false }
        for s in mine where s.status != .exited && !shown.contains(s.id) && !closed.contains(s.id) {
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
}
