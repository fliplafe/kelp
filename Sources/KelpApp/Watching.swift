import AppKit
import Core

/// What the views watch (`WatchTopic`), counted here so the daemon hears once per topic and key: on the first watcher
/// and after the last. What it pushes lands in AppModel's observed state (`git`, `ports`…), which views `track`.
extension AppModel {
    func watch(_ topic: WatchTopic, _ key: String = "") {
        let w = WatchStart(topic, key)
        watching[w, default: 0] += 1
        if watching[w] == 1 { client?.notify(w) }
    }

    func unwatch(_ topic: WatchTopic, _ key: String = "") {
        let w = WatchStart(topic, key)
        guard let n = watching[w] else { return }
        if n > 1 { watching[w] = n - 1; return }
        watching[w] = nil
        client?.notify(WatchStop(topic, key))
        forget(topic, key)   // not shown anywhere now: no stale value when it's watched again
    }

    /// Read it again now, and (CI) keep looking for a while: after a push, its run shows up within seconds.
    func watchAgain(_ topic: WatchTopic, _ key: String = "") {
        let w = WatchStart(topic, key)
        if watching[w] != nil { client?.notify(w) }
    }

    private func forget(_ topic: WatchTopic, _ key: String) {
        switch topic {
        case .git: git[key] = nil
        case .ports: ports[key] = nil
        case .activity: activity = nil
        case .ci: ci[key] = nil
        case .pr: prs[key] = nil
        case .context: contextShare[key] = nil
        case .limits: limits = nil
        }
    }

    /// What the daemon pushed for a watched topic. Assigned only when it differs: every assignment re-renders its readers.
    func watched(_ method: String, _ p: JSONValue) {
        func event<E: RPCEvent>(_: E.Type) -> E? { try? p.decode(E.self) }
        switch method {
        case GitEvent.name: if let e = event(GitEvent.self), git[e.worktree] != e { git[e.worktree] = e }
        case PortsEvent.name: if let e = event(PortsEvent.self), ports[e.worktree] != e.ports { ports[e.worktree] = e.ports }
        case ActivityEvent.name: if let e = event(ActivityEvent.self), activity != e { activity = e }
        case CIEvent.name: if let e = event(CIEvent.self), ci[e.worktree] != e { ci[e.worktree] = e }
        case PREvent.name: if let e = event(PREvent.self), prs[e.worktree] != e.pr { prs[e.worktree] = e.pr }
        case LimitsEvent.name: if let e = event(LimitsEvent.self), limits != e.usage { limits = e.usage }
        case ContextEvent.name:
            // No usage (not Claude Code, ended, just compacted) takes the ring away.
            guard let e = event(ContextEvent.self) else { return }
            let share = e.usage.flatMap { $0.window > 0 ? Double($0.used) / Double($0.window) : nil }
            if abs((contextShare[e.session] ?? -1) - (share ?? -1)) > 0.01 { contextShare[e.session] = share }
        default: break
        }
    }

    /// A project or workspace as it is now, or gone: the lists follow the daemon's records without reading them again.
    func record(_ method: String, _ p: JSONValue) {
        switch method {
        case Repo.name:
            guard let r = try? p.decode(Repo.self) else { return }
            recordEvents[r.id, default: 0] += 1
            if let i = repos.firstIndex(where: { $0.id == r.id }) { if repos[i] != r { repos[i] = r } } else { repos.append(r) }
        case Worktree.name:
            guard let w = try? p.decode(Worktree.self) else { return }
            recordEvents[w.id, default: 0] += 1
            if let i = worktrees.firstIndex(where: { $0.id == w.id }) { if worktrees[i] != w { worktrees[i] = w } } else { worktrees.append(w) }
        default:
            guard let e = try? p.decode(RemovedEvent.self) else { return }
            if let id = e.repo {
                for x in [id] + worktrees.filter({ $0.repoId == id }).map(\.id) { recordEvents[x, default: 0] += 1 }
                repos.removeAll { $0.id == id }; worktrees.removeAll { $0.repoId == id }
            }
            if let id = e.worktree { recordEvents[id, default: 0] += 1; worktrees.removeAll { $0.id == id } }
        }
    }

    /// The context ring of every agent that hasn't ended: watched while it runs, let go when it ends.
    func syncContextWatches() {
        let want = Set(sessions.filter { $0.agent != "shell" && $0.status != .exited }.map(\.id))
        let have = Set(watching.keys.filter { $0.topic == .context }.map(\.key))
        for id in want.subtracting(have) { watch(.context, id) }
        for id in have.subtracting(want) { unwatch(.context, id) }
    }
}

/// One key of a topic watched at a time (the workspace a panel shows): set `key`, nil lets go; so does the owner going.
@MainActor
final class Watched {
    let topic: WatchTopic
    var key: String? {
        didSet {
            guard key != oldValue else { return }
            if let o = oldValue { AppModel.shared.unwatch(topic, o) }
            if let k = key { AppModel.shared.watch(topic, k) }
        }
    }
    init(_ topic: WatchTopic) { self.topic = topic }
    isolated deinit { if let k = key { AppModel.shared.unwatch(topic, k) } }
}
