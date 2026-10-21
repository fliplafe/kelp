import Foundation
import AppKit
import Observation
import Core
import Agents

/// The agents the UI offers: the ones that actually run on this Mac (see AgentAvailability).
enum AgentCatalog {
    @MainActor static func installed(_ all: [AgentManifest]) -> [AgentManifest] {
        let ok = AgentAvailability.shared.ids
        return all.filter { ok.contains($0.id) }
    }

    /// Built-in and user agent manifests plus agents contributed by extensions.
    @MainActor static var all: [AgentManifest] {
        let base = AppModel.shared.agents
        return base + ExtensionRegistry.shared.all.agents.filter { a in !base.contains { $0.id == a.id } }
    }
    /// The agent "New Agent" starts: the setting if it's installed, else the first installed one.
    @MainActor static var defaultAgent: String {
        let installed = installed(all)
        if let d = SettingsStore.shared.string("agents.default"), installed.contains(where: { $0.id == d }) { return d }
        return installed.first?.id ?? "claude"
    }
    /// The default agent, nil while no agent CLI is found (nothing to start).
    @MainActor static var startable: String? { installed(all).isEmpty ? nil : defaultAgent }
    @MainActor static func name(_ id: String?) -> String {
        guard let id else { return "Terminal" }
        if id == "shell" { return "Terminal" }
        return all.first { $0.id == id }?.name ?? id.capitalized
    }

    /// Its title, or the agent's name — numbered when the same agent runs twice in one workspace.
    /// Sidebar, tabs, notifications and menus all use this, so they agree.
    @MainActor static func displayName(_ s: Session) -> String {
        if !s.title.isEmpty { return s.title }
        let same = AppModel.shared.sessions.filter { $0.worktreeId == s.worktreeId && $0.status != .exited && $0.title.isEmpty && $0.agent == s.agent }
            .sorted { $0.createdAt < $1.createdAt }
        let base = name(s.agent)
        guard same.count > 1, let i = same.firstIndex(where: { $0.id == s.id }), i > 0 else { return base }
        return "\(base) \(i + 1)"
    }

    /// The agent's real icon when there is one (AgentIcons), else its initial on a tile of the same shape; a terminal's symbol.
    @MainActor static func icon(_ id: String?, size: CGFloat = 16) -> NSImage? {
        guard let id, id != "shell", id != "custom" else { return .symbol(id == "custom" ? "apple.terminal" : "terminal") }
        guard let real = AgentIcons.shared.image(id)?.copy() as? NSImage else { return IconTile.letter(name(id), color: brand[id], size: size) }
        real.size = NSSize(width: size, height: size)
        return real
    }
    /// Colours for the initials of agents whose icon isn't found (yet): the vendor's, near enough.
    @MainActor private static let brand: [String: NSColor] = ["claude": NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
                                                              "codex": NSColor(white: 0.15, alpha: 1), "grok": NSColor(white: 0.15, alpha: 1),
                                                              "cursor": NSColor(white: 0.15, alpha: 1), "gemini": .systemBlue]
}

/// Which agent CLIs run on this Mac: found on the login shell's PATH and answering `--version` — a shim whose binary
/// is gone (a broken npm install) doesn't count. Checked in the background at launch and when Kelp comes back to the
/// front (at most every few minutes), so newly installed agents show up; the last answer is remembered for the next launch.
@MainActor
@Observable
final class AgentAvailability {
    static let shared = AgentAvailability()
    private(set) var ids = Set(UserDefaults.standard.stringArray(forKey: "agents.available") ?? [])
    @ObservationIgnored private var checkedAt = Date.distantPast
    @ObservationIgnored private var checking = false

    func refresh(force: Bool = false) {
        guard !checking, force || Date().timeIntervalSince(checkedAt) > 300 else { return }
        checking = true
        let commands = AgentCatalog.all.filter { $0.id != "custom" }.map { ($0.id, $0.command) }
        let ran = UserDefaults.standard.dictionary(forKey: "agents.ran") as? [String: Double] ?? [:]
        Task.detached(priority: .utility) {
            let found = await withTaskGroup(of: (id: String, binary: String)?.self) { g in
                for (id, command) in commands { g.addTask { await Self.runs(command, ran: ran).map { (id, $0) } } }
                var all: [(id: String, binary: String)] = []
                for await r in g { if let r { all.append(r) } }
                return all
            }
            let ok = Set(found.map(\.id)), now = Date().timeIntervalSince1970
            let keep = Dictionary(found.map { ($0.binary, ran[$0.binary] ?? now) }) { a, _ in a }
            await MainActor.run {
                let me = AgentAvailability.shared
                me.checking = false; me.checkedAt = Date()
                if ok != me.ids { me.ids = ok; UserDefaults.standard.set(Array(ok).sorted(), forKey: "agents.available") }
                UserDefaults.standard.set(keep, forKey: "agents.ran")
            }
        }
    }

    /// `<command> --version` exits 0 within a few seconds: then the binary (real path and modification time), else nil.
    /// One that ran in the last day (`ran`: binary → when) and hasn't changed isn't started again: a dozen agent CLIs at
    /// every launch cost seconds of CPU (one took 2 s). Waits without holding a thread (they're asked at once).
    nonisolated static func runs(_ command: String, ran: [String: Double] = [:]) async -> String? {
        guard let path = try? LoginPath.resolve(command), let real = Paths.real(path),
              let mtime = (try? FileManager.default.attributesOfItem(atPath: real)[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        let binary = "\(real)|\(mtime)"
        if let at = ran[binary], Date().timeIntervalSince1970 - at < 86400 { return binary }
        return await Shell.exec([path, "--version"], timeout: 8).code == 0 ? binary : nil   // hung: killed, counts as missing
    }
}
