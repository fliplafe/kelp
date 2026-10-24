import Foundation
import AppKit
import Observation
import Core
import Agents

/// The agents the UI offers: the ones that actually run on this Mac (see AgentAvailability). The app's (`app.catalog`).
@MainActor
package struct AgentCatalog {
    let app: AppModel
    func installed(_ all: [AgentManifest]) -> [AgentManifest] {
        let ok = app.availability.ids
        return all.filter { ok.contains($0.id) }
    }

    /// Built-in and user agent manifests plus agents contributed by extensions.
    package var all: [AgentManifest] {
        let base = app.agents
        return base + app.extensions.all.agents.filter { a in !base.contains { $0.id == a.id } }
    }
    /// The agent "New Agent" starts: the setting if it's installed, else the first installed one.
    var defaultAgent: String {
        let installed = installed(all)
        if let d = app.settings.string("agents.default"), installed.contains(where: { $0.id == d }) { return d }
        return installed.first?.id ?? "claude"
    }
    /// Whether to offer tmux sessions in a workspace: tmux is on this Mac, or the project is on a host (which usually has
    /// it; tmux.list says so when it hasn't).
    func hasTmux(_ w: Worktree?) -> Bool {
        app.availability.ids.contains("tmux") || w.flatMap { RemoteHost.of($0.path) } != nil
    }
    /// The default agent, nil while no agent CLI is found (nothing to start).
    var startable: String? { installed(all).isEmpty ? nil : defaultAgent }
    func name(_ id: String?) -> String {
        guard let id else { return "Terminal" }
        if id == "shell" { return "Terminal" }
        return all.first { $0.id == id }?.name ?? id.capitalized
    }

    /// Its title, or the agent's name — numbered when the same agent runs twice in one workspace.
    /// Sidebar, tabs, notifications and menus all use this, so they agree.
    package func displayName(_ s: Session) -> String {
        if !s.title.isEmpty { return s.title }
        let same = app.sessions.filter { $0.worktreeId == s.worktreeId && $0.status != .exited && $0.title.isEmpty && $0.agent == s.agent }
            .sorted { $0.createdAt < $1.createdAt }
        let base = name(s.agent)
        guard same.count > 1, let i = same.firstIndex(where: { $0.id == s.id }), i > 0 else { return base }
        return "\(base) \(i + 1)"
    }

    /// What an agent is, in a few words: the empty workspace and Settings › Agents say it beside the name.
    package func about(_ id: String) -> String? {
        switch id {
        case "claude": String(localized: "Anthropic’s coding agent")
        case "codex": String(localized: "OpenAI’s coding agent")
        case "gemini": String(localized: "Google’s agent, free with a Google account")
        case "opencode": String(localized: "Open source, works with any model provider")
        case "cursor": String(localized: "Cursor’s agent in the terminal")
        case "qwen": String(localized: "Alibaba’s open source agent")
        case "amp": String(localized: "Sourcegraph’s agent")
        case "copilot": String(localized: "GitHub Copilot in the terminal")
        case "auggie": String(localized: "Augment Code’s agent")
        case "crush": String(localized: "Charm’s open source agent, any model")
        case "aider": String(localized: "Pair programming in git, any model")
        case "droid": String(localized: "Factory’s agent")
        case "omp": String(localized: "Pi with an IDE’s tools wired in, any model")
        case "fx": String(localized: "Vercel’s small native agent, any model")
        default: nil
        }
    }
    /// What the empty workspace offers to install when no agent is on this Mac; the rest are in Settings › Agents.
    var suggested: [AgentManifest] {
        ["claude", "codex", "gemini", "opencode", "cursor"].compactMap { id in all.first { $0.id == id && $0.install != nil } }
    }
    /// The agent's own install command in a terminal tab of `e`, in plain sight; once it ends, the agent is looked for again.
    package func install(_ m: AgentManifest, in e: EditorArea) {
        guard let cmd = m.install else { return }
        e.run(command: cmd, title: String(localized: "Install \(m.name)")) { [app] s in app.availability.watchInstall(s.id) }
    }

    /// The agent's real icon when there is one (AgentIcons), else its initial on a tile of the same shape; a terminal's symbol.
    package func icon(_ id: String?, size: CGFloat = 16) -> NSImage? {
        guard let id, id != "shell", id != "custom" else { return .symbol(id == "custom" ? "apple.terminal" : "terminal") }
        guard let real = app.agentIcons.image(id)?.copy() as? NSImage else { return IconTile.letter(name(id), color: Self.brand[id], size: size) }
        real.size = NSSize(width: size, height: size)
        return real
    }
    /// Colours for the initials of agents whose icon isn't found (yet): the vendor's, near enough.
    private static let brand: [String: NSColor] = ["claude": NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
                                                   "codex": NSColor(white: 0.15, alpha: 1), "grok": NSColor(white: 0.15, alpha: 1),
                                                   "cursor": NSColor(white: 0.15, alpha: 1), "gemini": .systemBlue]
}

extension AppModel {
    /// The agents it offers (see `AgentCatalog`).
    package var catalog: AgentCatalog { AgentCatalog(app: self) }
}

/// Which agent CLIs run on this Mac: found on the login shell's PATH and answering `--version` — a shim whose binary
/// is gone (a broken npm install) doesn't count. Checked in the background at launch and when Kelp comes back to the
/// front (at most every few minutes), so newly installed agents show up; the last answer is remembered for the next launch.
@MainActor
@Observable
package final class AgentAvailability {
    @ObservationIgnored let app: AppModel
    init(app: AppModel) { self.app = app }
    private(set) package var ids = Set(UserDefaults.standard.stringArray(forKey: "agents.available") ?? [])
    @ObservationIgnored private var checkedAt = Date.distantPast
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var installs = Set<String>()

    /// An install running in session `id`: when it ends, the agents are looked for again (no wait for the next check).
    func watchInstall(_ id: String) { installs.insert(id) }
    func sessionChanged(_ s: Session) {
        if s.status == .exited, installs.remove(s.id) != nil { refresh(force: true) }
    }

    package func refresh(force: Bool = false) {
        let app = self.app
        guard !checking, force || Date().timeIntervalSince(checkedAt) > 300 else { return }
        checking = true
        let commands = app.catalog.all.filter { $0.id != "custom" }.map { ($0.id, $0.command) }
        let ran = UserDefaults.standard.dictionary(forKey: "agents.ran") as? [String: Double] ?? [:]
        Task.detached(priority: .utility) {
            // The daemon runs the `--version`s: without it every agent would look missing. Asked again next time.
            await app.waitForConnection()
            guard await MainActor.run(body: { app.connected }) else {
                await MainActor.run { self.checking = false }; return
            }
            // Where the daemon finds them on its login-shell PATH ("tmux" too); not knowing, nothing changes.
            guard let paths = await app.quiet(ProcessWhich(commands: commands.map(\.1) + ["tmux"])) else {
                await MainActor.run { self.checking = false }; return
            }
            let found = await withTaskGroup(of: (id: String, binary: String)?.self) { g in
                for (id, command) in commands { if let path = paths[command] { g.addTask { await Self.runs(path, ran: ran, app: app).map { (id, $0) } } } }
                var all: [(id: String, binary: String)] = []
                for await r in g { if let r { all.append(r) } }
                return all
            }
            // Not an agent: "tmux" among the ids only says there's a tmux here to attach to (AgentCatalog.hasTmux).
            let tmux = paths["tmux"] != nil
            let ok = Set(found.map(\.id) + (tmux ? ["tmux"] : [])), now = Date().timeIntervalSince1970
            let keep = Dictionary(found.map { ($0.binary, ran[$0.binary] ?? now) }) { a, _ in a }
            await MainActor.run {
                let me = self
                me.checking = false; me.checkedAt = Date()
                if ok != me.ids { me.ids = ok; UserDefaults.standard.set(Array(ok).sorted(), forKey: "agents.available") }
                UserDefaults.standard.set(keep, forKey: "agents.ran")
            }
        }
    }

    /// `<path> --version` exits 0 within a few seconds: then the binary (real path and modification time), else nil.
    /// One that ran in the last day (`ran`: binary → when) and hasn't changed isn't started again: a dozen agent CLIs at
    /// every launch cost seconds of CPU (one took 2 s). Waits without holding a thread (they're asked at once).
    nonisolated static func runs(_ path: String, ran: [String: Double] = [:], app: AppModel) async -> String? {
        guard let real = Paths.real(path),
              let mtime = (try? FileManager.default.attributesOfItem(atPath: real)[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        let binary = "\(real)|\(mtime)"
        if let at = ran[binary], Date().timeIntervalSince1970 - at < 86400 { return binary }
        return await Shell.exec(app, [path, "--version"], timeout: 8).code == 0 ? binary : nil   // hung: killed, counts as missing
    }
}
