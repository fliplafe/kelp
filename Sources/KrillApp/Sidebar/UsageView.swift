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
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
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
                    ForEach(rows) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(r.agent) · \(r.kind)").font(.caption)
                                Spacer()
                                if let u = r.used { Text("\(Int(u * 100))% used").font(.caption2.monospacedDigit()).foregroundStyle(color(u)) }
                            }
                            if let u = r.used { ProgressView(value: min(u, 1)).progressViewStyle(.linear).tint(color(u)).controlSize(.mini) }
                            Text(r.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .help("\(r.agent) \(r.kind): \(r.detail)")
                    }
                }
            }
        }
        EmptyView()
            .task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(60))
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
        for l in u["claudeLimits"]?.array ?? [] {   // percentages Claude Code printed itself
            out.append(Row(agent: "Claude", kind: l["kind"]?.string ?? "limit", used: num(l["percent"]).map { $0 / 100 },
                           detail: l["resets"]?.string.map { "resets \($0)" } ?? "as reported by Claude Code"))
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
