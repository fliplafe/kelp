import AppKit
import SwiftUI
import Core
import GitKit

/// What a sidebar row holds, in full, when the pointer rests on it: the row itself stays one line.
/// After half a second the card appears; while one is open, moving to another row shows that row's card at once.
@MainActor
final class HoverCard {
    private let popover = NSPopover()
    private var pending: DispatchWorkItem?
    private(set) var shownKey: String?
    private var warmUntil = Date.distantPast

    init() { popover.behavior = .applicationDefined; popover.animates = false }

    /// The pointer is over a row (`key` "w:…" / "a:…"), or over nothing.
    func hover(_ key: String?, rect: NSRect, in view: NSView) {
        guard key != shownKey || !popover.isShown else { return }
        pending?.cancel()
        guard let key else {
            let w = DispatchWorkItem { [weak self] in self?.close() }
            pending = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
            return
        }
        let w = DispatchWorkItem { [weak self, weak view] in if let view { self?.show(key, rect: rect, in: view) } }
        pending = w
        let warm = popover.isShown || Date() < warmUntil
        DispatchQueue.main.asyncAfter(deadline: .now() + (warm ? 0 : 0.5), execute: w)
    }

    func close() {
        pending?.cancel()
        if popover.isShown { warmUntil = Date().addingTimeInterval(0.8); popover.close() }
        shownKey = nil
    }

    private func show(_ key: String, rect: NSRect, in view: NSView) {
        guard view.window != nil, let model = CardModel(key) else { close(); return }   // events come only while the window is key
        shownKey = key
        popover.contentViewController = NSHostingController(rootView: CardView(model: model))
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        model.load()
    }
}

/// The card's contents: what the sidebar knows now, then what git, GitHub and the agent's transcript add.
@MainActor
@Observable
final class CardModel {
    struct Agent: Identifiable { let id: String; let session: Session }
    let title: String, subtitle: String
    let agents: [Agent]
    let workspaceId: String
    let agentOnly: Bool
    var changes: LineStats?
    var pr: JSONValue?
    var turn: String?
    var context: (used: Int, window: Int)?
    var ports: [Int] = []

    init?(_ key: String) {
        let m = AppModel.shared
        if key.hasPrefix("a:"), let s = m.session(String(key.dropFirst(2))) {
            title = AgentCatalog.displayName(s)
            let w = m.worktree(s.worktreeId)
            subtitle = [w?.displayName, m.repo(w?.repoId)?.name].compactMap { $0 }.joined(separator: " · ")
            agents = [Agent(id: s.id, session: s)]; workspaceId = s.worktreeId ?? ""; agentOnly = true
        } else if key.hasPrefix("w:"), let w = m.worktree(String(key.dropFirst(2))) {
            let r = m.repo(w.repoId)
            title = w.displayName
            subtitle = [r?.name, w.path == r?.path ? nil : "branch \(w.branch)"].compactMap { $0 }.joined(separator: " · ")
            agents = m.sessions.filter { $0.worktreeId == w.id && $0.agent != "shell" && $0.status != .exited }.map { Agent(id: $0.id, session: $0) }
            workspaceId = w.id; agentOnly = false
        } else { return nil }
    }

    func load() {
        guard let c = AppModel.shared.client else { return }
        let wid = JSONValue.obj(["id": .string(workspaceId)])
        Task {
            if !agentOnly {
                changes = try? await c.call("git.lineStats", wid, as: LineStats.self)
                let p = try? await c.call("github.branchPR", .obj(["worktreeId": .string(workspaceId)]))
                if p?["number"] != nil { pr = p }
                ports = ((try? await c.call("ports.list", .obj(["worktreeId": .string(workspaceId)])).array) ?? []).compactMap { $0["port"]?.int }
            }
            guard agentOnly, let a = agents.first else { return }
            let id = JSONValue.obj(["id": .string(a.id)])
            if let t = (try? await c.call("session.turn", id))?["turn"], case .object = t {
                let files = t["files"]?.array ?? []
                let add = files.reduce(0) { $0 + ($1["added"]?.int ?? 0) }, del = files.reduce(0) { $0 + ($1["removed"]?.int ?? 0) }
                let secs = Int(t["seconds"].flatMap { if case .double(let d) = $0 { d } else { $0.int.map(Double.init) } } ?? 0)
                let took = secs < 60 ? "\(secs)s" : "\(secs / 60)m"
                turn = files.isEmpty ? String(localized: "Last turn changed no files · \(took)")
                    : "Last turn: \(files.count) \(files.count == 1 ? "file" : "files") +\(add) −\(del) · \(took)"
            }
            if let u = try? await c.call("session.contextWindow", id), let used = u["used"]?.int, let window = u["window"]?.int { context = (used, window) }
        }
    }
}

struct CardView: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline).lineLimit(2)
                if !model.subtitle.isEmpty { Text(model.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let pr = model.pr { PRLine(pr: pr) }
            if let c = model.changes, c.totalAdded + c.totalRemoved > 0 {
                (Text("Not committed  ") + Text(c.totalAdded > 0 ? "+\(c.totalAdded)" : "").foregroundColor(.green)
                    + Text(c.totalAdded > 0 && c.totalRemoved > 0 ? " " : "") + Text(c.totalRemoved > 0 ? "−\(c.totalRemoved)" : "").foregroundColor(.red))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(model.agents) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        StatusIcon(status: a.session.status).font(.caption)
                        Text(model.agentOnly ? a.session.status.words : AgentCatalog.displayName(a.session)).font(.callout).lineLimit(1)
                        if !model.agentOnly { Text(a.session.status.words).font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 8)
                        Text(shortAgo(a.session.statusAt ?? a.session.createdAt)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    if !a.session.summary.isEmpty {
                        Text(a.session.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !model.ports.isEmpty {
                Text("Serving " + model.ports.map { "localhost:\($0)" }.joined(separator: ", ")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let t = model.turn { Text(t).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if let c = model.context { ContextLine(used: c.used, window: c.window) }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }
}

/// "#123 Fix login · Open · ✓ 5 checks": a PR in GitHub's own colours (open green, draft grey, merged purple, closed red).
struct PRLine: View {
    let pr: JSONValue
    var body: some View {
        let state = pr["isDraft"]?.bool == true ? String(localized: "Draft") : (pr["state"]?.string ?? "").capitalized
        let color: Color = state == String(localized: "Draft") ? .secondary : state == "Merged" ? .purple : state == "Closed" ? .red : .green
        let checks = pr["checks"]
        let failed = checks?["failed"]?.int ?? 0, pending = checks?["pending"]?.int ?? 0, passed = checks?["passed"]?.int ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: state == "Merged" ? "arrow.triangle.merge" : "arrow.triangle.pull").foregroundStyle(color)
                Text("#\(pr["number"]?.int ?? 0)").font(.callout.monospacedDigit())
                Text(pr["title"]?.string ?? "").font(.callout).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(state).foregroundStyle(color)
                if failed > 0 { Text("✕ \(failed) failing").foregroundStyle(.red) }
                else if pending > 0 { Text("● \(pending) running").foregroundStyle(.orange) }
                else if passed > 0 { Text("✓ checks passed").foregroundStyle(.green) }
            }.font(.caption)
        }
    }
}

/// How full the agent's conversation is; amber from three quarters, red from nine tenths.
struct ContextLine: View {
    let used: Int, window: Int
    var body: some View {
        let share = min(1, Double(used) / Double(max(1, window)))
        let color: Color = share >= 0.9 ? .red : share >= 0.75 ? .orange : .secondary
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: share).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            }.frame(width: 11, height: 11)
            Text("Context \(Int(share * 100))% · \(used / 1000)k of \(window / 1000)k tokens").font(.caption.monospacedDigit()).foregroundStyle(color)
        }
    }
}
