import SwiftUI
import Core

/// How much of each agent's plan is used: a line per agent that reports it — name, a bar and the percentage of its
/// fullest limit — and the details (each limit, when it resets) on hover.
/// The numbers come from the agents' own /usage screens (Claude Code, Grok, Antigravity — the daemon reads them) and
/// Codex's session logs; agents that don't report limits aren't listed.
struct UsageView: View {
    struct Line: Equatable { var label: String; var used: Double; var resets: String? }   // used: 0...1
    struct Row: Identifiable, Equatable {
        var id: String, name: String, fullName: String
        var lines: [Line] = []
        /// When the numbers were read (nil: unknown); past half an hour they're dimmed and say how old they are.
        var readAt: Date?
        var stale: Bool { readAt.map { Date().timeIntervalSince($0) > 1800 } ?? false }
        var used: Double { lines.map(\.used).max() ?? 0 }
    }
    @State private var rows: [Row] = []
    @State private var hovered: String?

    var body: some View {
        // The loader hangs off a container that always exists: on an EmptyView `.task` never runs.
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                Divider()
                bars.padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .onChange(of: AgentAvailability.shared.ids) { Task { await load() } }
        .task {
            // Look again soon until the daemon answers (at launch) and has read the agents' /usage (seconds, the first time).
            var quick = 12
            while !Task.isCancelled {
                await load()
                let waiting = quick > 0 && !rows.contains { $0.id == "claude" }
                quick -= 1
                // Every 20 s: cheap (the daemon answers from memory), and a plan read after a turn shows up soon.
                try? await Task.sleep(for: .seconds(waiting ? (rows.isEmpty ? 1 : 8) : 20))
            }
        }
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows) { r in
                HStack(spacing: 8) {
                    Text(r.name).font(.caption).lineLimit(1).frame(width: 64, alignment: .leading)
                    Bar(used: r.used)
                    Text("\(Int((r.used * 100).rounded()))%").font(.caption).monospacedDigit()
                        .foregroundStyle(UsageView.tint(r.used)).frame(width: 34, alignment: .trailing)
                }
                .opacity(r.stale ? 0.45 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
                .onTapGesture { hovered = r.id }   // trackpads, and anyone who'd rather click
                .popover(isPresented: Binding(get: { hovered == r.id }, set: { if !$0, hovered == r.id { hovered = nil } }), arrowEdge: .top) {
                    Details(row: r)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(r.lines.map { String(localized: "\(r.fullName) \($0.label): \(Int(($0.used * 100).rounded()))% used") }.joined(separator: ", "))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How full the fullest limit is (a bar can't be mistaken for the "working" spinner); orange from 70 %, red from 90 %.
    private struct Bar: View {
        let used: Double
        var body: some View {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(UsageView.tint(used)).frame(width: max(4, g.size.width * min(used, 1)))
                }
            }
            .frame(height: 4)
        }
    }

    private struct Details: View {
        let row: Row
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.fullName).font(.headline)
                if let at = row.readAt {
                    Text(row.stale ? String(localized: "Read \(shortAgo(at)) ago; not since, so these may be out of date.") : String(localized: "Read \(shortAgo(at)) ago"))
                        .font(.caption).foregroundStyle(row.stale ? .orange : .secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(row.lines, id: \.label) { l in
                        GridRow {
                            Text(l.label).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Text("\(Int((l.used * 100).rounded()))%").monospacedDigit().fontWeight(.semibold).foregroundStyle(UsageView.tint(l.used, quiet: .primary))
                                if let r = l.resets { Text("· resets \(r)").foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .font(.callout)
            .padding(12)
        }
    }

    static func tint(_ u: Double, quiet: Color = .secondary) -> Color { u >= 0.9 ? .red : u >= 0.7 ? .orange : quiet }

    private func load() async {
        // The poll awaits each answer: without a timeout one lost reply froze the limits for good ("Read 36m ago; not since").
        guard let c = AppModel.shared.client, let u = try? await c.call("usage.get", timeout: 60) else { return }
        let next = AgentCatalog.installed(AgentCatalog.all).compactMap { a -> Row? in
            var r = Row(id: a.id, name: Self.short(a.name), fullName: a.name)
            r.readAt = Self.num(u["plansReadAt"]?[a.id]).map { Date(timeIntervalSince1970: $0) }
            switch a.id {
            case "claude": r.lines = Self.claude(u)
            case "codex": r.lines = Self.codex(u)
            default: r.lines = Self.lines(u["plans"]?[a.id]?.array ?? [])
            }
            return r.lines.isEmpty ? nil : r
        }
        if next != rows { rows = next }
    }

    /// "Claude Code" → "Claude", "Cursor Agent" → "Cursor": room for three in a sidebar.
    static func short(_ name: String) -> String {
        [" Code", " CLI", " Agent"].reduce(name) { $0.hasSuffix($1) ? String($0.dropLast($1.count)) : $0 }
    }

    private static func num(_ v: JSONValue?) -> Double? {
        switch v {
        case .double(let d)?: d
        case .int(let i)?: Double(i)
        default: nil
        }
    }

    /// Readings as the daemon passes them: kind ("session", "week", "week · Fable", "Gemini week"), percent, resets.
    private static func lines(_ readings: [JSONValue]) -> [Line] {
        readings.compactMap { l in
            guard let kind = l["kind"]?.string, let p = num(l["percent"]) else { return nil }
            let label = kind == "session" ? String(localized: "5 hours") : kind == "week" ? String(localized: "Week")
                : kind.hasPrefix("week · ") ? String(localized: "Week, ") + kind.dropFirst(7) : kind.prefix(1).uppercased() + kind.dropFirst()
            return Line(label: label, used: p / 100, resets: l["resets"]?.string)
        }
    }

    /// Claude Code's /usage, or the percentages a session printed.
    private static func claude(_ u: JSONValue) -> [Line] {
        lines(u["plans"]?["claude"]?.array ?? u["claudeLimits"]?.array ?? [])
    }

    private static func codex(_ u: JSONValue) -> [Line] {
        guard let x = u["codex"]?.array?.first else { return [] }
        let now = Date().timeIntervalSince1970
        return [(String(localized: "5 hours"), "primaryUsedPercent", "primaryResetsAt"), (String(localized: "Week"), "secondaryUsedPercent", "secondaryResetsAt")].compactMap { label, used, reset in
            guard let p = num(x[used]) else { return nil }
            let t = num(x[reset]) ?? 0, expired = t > 0 && t < now
            return Line(label: label, used: expired ? 0 : p / 100, resets: t > now ? Self.until(t) : nil)
        }
    }

    private static func until(_ ts: Double) -> String {
        let s = max(0, ts - Date().timeIntervalSince1970)
        return "in " + (s >= 86400 ? String(localized: "\(Int(s) / 86400)d \(Int(s) % 86400 / 3600)h") : String(localized: "\(Int(s) / 3600)h \(Int(s) % 3600 / 60)m"))
    }
}
