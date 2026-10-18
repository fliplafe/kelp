import SwiftUI
import Core

/// The focused agent: what it's doing, its subagents, and what you can do with it.
struct AgentPanel: View {
    private var bench = Workbench.shared
    private var model = AppModel.shared

    var body: some View {
        if let sid = bench.focusedSession, let s = model.session(sid) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        StatusIcon(status: s.status).font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title.isEmpty ? AgentCatalog.name(s.agent) : s.title).font(.headline).lineLimit(2)
                            Text("\(AgentCatalog.name(s.agent)) · \(s.status.words)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !s.summary.isEmpty {
                        Text(s.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let subs = model.subagents[sid], !subs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Subagents").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(Array(subs.enumerated()), id: \.offset) { _, sub in
                                Label { Text(sub.title).lineLimit(1) } icon: {
                                    Image(systemName: sub.active ? "circle.dotted" : "checkmark.circle").foregroundStyle(sub.active ? .blue : .secondary)
                                        .symbolEffect(.variableColor.iterative, isActive: sub.active)
                                }
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Button { AgentActions.restart(sid) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        Button { AgentActions.fork(sid) } label: { Label("Fork to New Workspace…", systemImage: "arrow.triangle.branch") }
                        Button { AgentActions.handoff(sid) } label: { Label("Hand Off to Another Agent…", systemImage: "arrow.right.circle") }
                        Button { AgentActions.copyContext(sid) } label: { Label("Copy Context", systemImage: "doc.on.doc") }
                    }
                    .buttonStyle(.link)
                    Text(s.cwd).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No Agent", systemImage: "sparkles", description: Text("Focus an agent tab to see what it's doing."))
        }
    }
}

/// Status as an SF Symbol, animated while the agent works.
struct StatusIcon: View {
    let status: AgentStatus
    var body: some View {
        Image(systemName: status == .working ? "circle.dotted" : status.symbol)
            .foregroundStyle(status.color)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: status == .working)
            .help(status.words)
    }
}
