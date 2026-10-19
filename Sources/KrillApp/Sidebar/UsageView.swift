import SwiftUI
import Core

/// How much of each installed agent's plan is used, one line per agent: the short window and the week.
/// The numbers come from the agents' own /usage screens (Claude Code, Grok, Antigravity — the daemon reads them) and Codex's session logs;
/// agents that don't report limits get a dash. Reset times and per-model limits are on hover.
struct UsageView: View {
    struct Gauge: Equatable { var label: String; var used: Double }   // 0...1
    struct Row: Identifiable, Equatable {
        var id: String, name: String, symbol: String
        var gauges: [Gauge] = []
        var note = "—"          // when there are no gauges
        var help: String
    }
    @State private var rows: [Row] = []
    @State private var expanded = UserDefaults.standard.object(forKey: "usage.expanded") as? Bool ?? true

    var body: some View {
        // The loader hangs off a container that always exists: on an EmptyView `.task` never runs.
        VStack(alignment: .leading, spacing: 0) { list }
            .onChange(of: AgentAvailability.shared.ids) { Task { await load() } }
            .task {
                // Look again soon until the daemon answers (at launch) and has read Claude's /usage (seconds, the first time).
                var quick = 12
                while !Task.isCancelled {
                    await load()
                    let waiting = quick > 0 && !rows.contains { $0.id == "claude" && !$0.gauges.isEmpty }
                    quick -= 1
                    try? await Task.sleep(for: .seconds(waiting ? (rows.isEmpty ? 1 : 8) : 60))
                }
            }
    }

    @ViewBuilder private var list: some View {
        if rows.contains(where: { !$0.gauges.isEmpty || $0.note != "—" }) {
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Button { expanded.toggle(); UserDefaults.standard.set(expanded, forKey: "usage.expanded") } label: {
                    HStack(spacing: 4) {
                        Text("Limits").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer()
                        if !expanded, let worst = rows.flatMap(\.gauges).map(\.used).max() { percent(worst) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    // Only agents that report their limits; the others have nothing to show here.
                    ForEach(rows.filter { !$0.gauges.isEmpty || $0.note != "—" }) { r in
                        HStack(spacing: 6) {
                            if let img = AgentIcons.shared.image(r.id) {
                                Image(nsImage: img).resizable().interpolation(.high).frame(width: 14, height: 14)
                            } else {
                                Image(systemName: r.symbol).font(.caption).foregroundStyle(.secondary).frame(width: 14)
                            }
                            Text(r.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            if r.gauges.isEmpty { Text(r.note).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                            ForEach(r.gauges, id: \.label) { g in
                                HStack(spacing: 3) { Text(g.label).foregroundStyle(.tertiary); percent(g.used) }.font(.caption)
                            }
                        }
                        .help(r.help)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func percent(_ u: Double) -> some View {
        Text("\(Int((u * 100).rounded()))%").font(.caption.monospacedDigit())
            .foregroundStyle(u >= 0.9 ? Color.red : u >= 0.7 ? Color.orange : Color.secondary)
    }

    private func load() async {
        guard let c = AppModel.shared.client, let u = try? await c.call("usage.get") else { return }
        let next = AgentCatalog.installed(AgentCatalog.all).filter { $0.id != "custom" }.map { a in
            var r = Row(id: a.id, name: a.name, symbol: AgentCatalog.symbol(a.id), help: "\(a.name) doesn't report its usage limits.")
            switch a.id {
            case "claude": Self.claude(u, into: &r)
            case "codex": Self.codex(u, into: &r)
            default: Self.plan(u["plans"]?[a.id]?.array ?? [], into: &r)
            }
            return r
        }
        if next != rows { rows = next }
    }

    private static func num(_ v: JSONValue?) -> Double? {
        switch v {
        case .double(let d)?: d
        case .int(let i)?: Double(i)
        default: nil
        }
    }
    private static func until(_ ts: Double) -> String {
        let s = max(0, ts - Date().timeIntervalSince1970)
        return s < 60 ? "resets now" : "resets in " + (s >= 86400 ? "\(Int(s) / 86400)d \(Int(s) % 86400 / 3600)h" : "\(Int(s) / 3600)h \(Int(s) % 3600 / 60)m")
    }

    /// Claude Code's /usage (or the percentages a session printed): session → "5h", all-model week → "week".
    private static func claude(_ u: JSONValue, into r: inout Row) {
        let readings = u["plans"]?["claude"]?.array ?? u["claudeLimits"]?.array ?? []
        for l in readings {
            guard let kind = l["kind"]?.string, let p = num(l["percent"]) else { continue }
            if kind == "session" { r.gauges.append(Gauge(label: "5h", used: p / 100)) }
            if kind == "week" { r.gauges.append(Gauge(label: "week", used: p / 100)) }
        }
        if !readings.isEmpty {
            r.help = readings.compactMap { l in
                guard let kind = l["kind"]?.string, let p = num(l["percent"]) else { return nil }
                let name = kind == "session" ? "5-hour session" : kind == "week" ? "Week, all models" : kind.replacingOccurrences(of: "week · ", with: "Week, ")
                return "\(name): \(Int(p))% used" + (l["resets"]?.string.map { " · resets \($0)" } ?? "")
            }.joined(separator: "\n")
        } else if let b = u["claude"]?.array?.first?["block"] {
            r.note = String(format: "$%.0f in 5h", num(b["cost"]) ?? 0)
            r.help = "Spent in the current 5-hour window, " + until(num(b["end"]) ?? 0) + ". Exact limits appear once Claude Code is signed in."
        }
    }

    /// Grok, Antigravity: their weekly limit — for Antigravity's model groups the fullest one; every group is on hover.
    private static func plan(_ readings: [JSONValue], into r: inout Row) {
        guard let worst = readings.compactMap({ num($0["percent"]) }).max() else { return }
        r.gauges = [Gauge(label: "week", used: worst / 100)]
        r.help = readings.compactMap { l in
            guard let kind = l["kind"]?.string, let p = num(l["percent"]) else { return nil }
            return "\(kind.prefix(1).uppercased() + kind.dropFirst()): \(Int(p))% used" + (l["resets"]?.string.map { " · resets \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    private static func codex(_ u: JSONValue, into r: inout Row) {
        guard let x = u["codex"]?.array?.first else { return }
        let now = Date().timeIntervalSince1970
        var help: [String] = []
        for (label, name, used, reset) in [("5h", "5-hour window", "primaryUsedPercent", "primaryResetsAt"), ("week", "Week", "secondaryUsedPercent", "secondaryResetsAt")] {
            guard let p = num(x[used]) else { continue }
            let t = num(x[reset]) ?? 0, expired = t > 0 && t < now
            r.gauges.append(Gauge(label: label, used: expired ? 0 : p / 100))
            help.append("\(name): \(expired ? 0 : Int(p))% used · " + (expired ? "reset since the last session" : until(t)))
        }
        if !help.isEmpty { r.help = help.joined(separator: "\n") }
    }
}
