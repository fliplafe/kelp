import SwiftUI
import Core

/// How much of each agent's plan is left: Codex rate-limit windows, Claude's limits when it reports them
/// (otherwise the current 5-hour window from local transcripts). Refreshes every minute.
struct UsageView: View {
    @State private var rows: [Row] = []
    @State private var expanded = UserDefaults.standard.object(forKey: "usage.expanded") as? Bool ?? true

    struct Row: Identifiable, Equatable {
        var id: String { agent + kind }
        var agent: String, kind: String
        var used: Double?          // 0...1 when known
        var detail: String
    }

    var body: some View {
        // The loader hangs off a container that always exists: on an EmptyView `.task` never runs.
        VStack(alignment: .leading, spacing: 0) { list }
            .task {
                // Look again soon until the daemon answers (at launch) and has read Claude's /usage (seconds, the first time).
                var quick = 12
                while !Task.isCancelled {
                    await load()
                    let waiting = quick > 0 && !rows.contains { $0.agent == "Claude" && $0.used != nil }
                    quick -= 1
                    try? await Task.sleep(for: .seconds(waiting ? (rows.isEmpty ? 1 : 8) : 60))
                }
            }
    }

    @ViewBuilder private var list: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Button { expanded.toggle(); UserDefaults.standard.set(expanded, forKey: "usage.expanded") } label: {
                    HStack(spacing: 4) {
                        Text("Limits").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer()
                        if !expanded, let worst = rows.compactMap(\.used).max() { Text("\(Int(worst * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(color(worst)) }
                    }
                }
                .buttonStyle(.plain)
                if expanded {
                    // One line each, like a status footer; when it resets is on hover.
                    ForEach(rows) { r in
                        HStack(spacing: 6) {
                            Text("\(r.agent) \(r.kind)").font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            if let u = r.used {
                                ProgressView(value: min(u, 1)).progressViewStyle(.linear).tint(color(u)).controlSize(.mini).frame(width: 54)
                                Text("\(Int(u * 100))%").font(.caption.monospacedDigit()).foregroundStyle(color(u)).frame(width: 32, alignment: .trailing)
                            } else {
                                Text(r.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .help("\(r.agent) \(r.kind): \(r.detail)")
                    }
                }
            }
        }
    }

    private func color(_ u: Double) -> Color { u >= 0.9 ? .red : u >= 0.7 ? .orange : .accentColor }

    private func load() async {
        guard let c = AppModel.shared.client, let u = try? await c.call("usage.get") else { return }
        func num(_ v: JSONValue?) -> Double? {
            switch v {
            case .double(let d)?: d
            case .int(let i)?: Double(i)
            default: nil
            }
        }
        func until(_ ts: Double) -> String {
            let s = max(0, ts - Date().timeIntervalSince1970)
            return s < 60 ? "resets now" : "resets in " + (s >= 86400 ? "\(Int(s) / 86400)d \(Int(s) % 86400 / 3600)h" : "\(Int(s) / 3600)h \(Int(s) % 3600 / 60)m")
        }
        var out: [Row] = []
        for l in u["claudePlan"]?.array ?? [] {   // Claude Code's own /usage screen
            out.append(Row(agent: "Claude", kind: l["kind"]?.string ?? "limit", used: num(l["percent"]).map { $0 / 100 },
                           detail: l["resets"]?.string.map { "resets \($0)" } ?? ""))
        }
        if out.isEmpty {
            for l in u["claudeLimits"]?.array ?? [] {   // percentages Claude Code printed in a session
                out.append(Row(agent: "Claude", kind: l["kind"]?.string ?? "limit", used: num(l["percent"]).map { $0 / 100 },
                               detail: l["resets"]?.string.map { "resets \($0)" } ?? "as reported by Claude Code"))
            }
        }
        if out.isEmpty {
            for cl in u["claude"]?.array ?? [] {
                guard let b = cl["block"] else { continue }
                let cost = num(b["cost"]) ?? 0
                out.append(Row(agent: "Claude", kind: "5-hour window", used: nil,
                               detail: String(format: "$%.2f so far · ", cost) + until(num(b["end"]) ?? 0)))
            }
        }
        let now = Date().timeIntervalSince1970
        for x in u["codex"]?.array ?? [] {
            for (kind, used, reset) in [("5-hour", "primaryUsedPercent", "primaryResetsAt"), ("week", "secondaryUsedPercent", "secondaryResetsAt")] {
                guard let p = num(x[used]) else { continue }
                let r = num(x[reset]) ?? 0
                out.append(Row(agent: "Codex", kind: kind, used: r > 0 && r < now ? 0 : p / 100, detail: r > 0 && r < now ? "reset since last session" : until(r)))
            }
        }
        if out != rows { rows = out }
    }
}
