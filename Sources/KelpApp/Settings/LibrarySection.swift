import SwiftUI
import Core

/// Settings › Extensions › Library: what github.com/nikiomori/kelp-extensions holds, read when the pane shows,
/// to install or bring up to date.
struct LibrarySection: View {
    private var registry = ExtensionRegistry.shared
    @State private var entries: [ExtensionLibrary.Entry]?
    @State private var error: String?
    /// The first required command each one lacks on this Mac.
    @State private var missing: [String: String] = [:]
    @State private var installing: String?

    var body: some View {
        Section {
            if let error {
                HStack {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Try Again") { Task { await load() } }
                }
            } else if let entries {
                if entries.isEmpty { Text("Nothing in the library yet.").foregroundStyle(.secondary) }
                ForEach(entries, id: \.id) { row($0) }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
            }
        } header: {
            Text("Extensions people shared, each reviewed before it's added.")
        } footer: {
            if let url = URL(string: "https://github.com/\(IDE.libraryRepo)") { Link("Share Yours on GitHub", destination: url).font(.caption) }
        }
        .task { await load() }
    }

    private func row(_ e: ExtensionLibrary.Entry) -> some View {
        let have = registry.extensions.first { $0.id == e.id && !$0.builtin }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: e.icon ?? "puzzlepiece.extension").font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.name).fontWeight(.medium)
                    Text(e.version).font(.caption).foregroundStyle(.secondary)
                }
                if let d = e.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                if let m = missing[e.id] { Text("Needs `\(m)` — not found on this Mac.").font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer()
            if installing == e.id {
                ProgressView().controlSize(.small)
            } else if have == nil {
                Button("Install") { install(e) }
            } else if let s = have?.source, s != e.source {
                Button("Update") { install(e) }
            } else {
                Text("Already installed").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func install(_ e: ExtensionLibrary.Entry) {
        installing = e.id
        Task { _ = await registry.install(source: e.source); installing = nil }
    }

    private func load() async {
        error = nil
        do {
            let all = try await AppModel.shared.get(ExtensionLibrary())
            if ExtensionRegistry.pathReady {
                missing = Dictionary(uniqueKeysWithValues: all.compactMap { e in
                    (e.requires ?? []).first { (try? LoginPath.resolve($0)) == nil }.map { (e.id, $0) }
                })
            }
            entries = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            self.error = String(localized: "Couldn't load the library: \(AppModel.message(error))")
        }
    }
}
