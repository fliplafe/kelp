import Foundation
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
    @MainActor static func name(_ id: String?) -> String {
        guard let id else { return "Terminal" }
        if id == "shell" { return "Terminal" }
        return all.first { $0.id == id }?.name ?? id.capitalized
    }

    /// A few agents have a fitting symbol; any other one gets its initial in a circle.
    static func symbol(_ id: String?) -> String {
        switch id {
        case "claude": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "gemini": "star.circle"
        case "opencode": "curlybraces"
        case "cursor": "cursorarrow.rays"
        case "amp": "bolt"
        case "shell", nil: "terminal"
        case "custom": "apple.terminal"
        case let id?: id.first.flatMap { $0.isASCII && $0.isLetter ? "\($0.lowercased()).circle" : nil } ?? "cpu"
        }
    }
}

/// Which agent CLIs run on this Mac: found on the login shell's PATH and answering `--version` — a shim whose binary
/// is gone (a broken npm install) doesn't count. Checked in the background at launch and when Krill comes back to the
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
        Task.detached(priority: .utility) {
            let ok = await withTaskGroup(of: String?.self) { g in
                for (id, command) in commands { g.addTask { Self.runs(command) ? id : nil } }
                var s = Set<String>()
                for await id in g { if let id { s.insert(id) } }
                return s
            }
            await MainActor.run {
                let me = AgentAvailability.shared
                me.checking = false; me.checkedAt = Date()
                if ok != me.ids { me.ids = ok; UserDefaults.standard.set(Array(ok).sorted(), forKey: "agents.available") }
            }
        }
    }

    /// `<command> --version` exits 0 within a few seconds.
    nonisolated static func runs(_ command: String) -> Bool {
        guard let path = try? LoginPath.resolve(command) else { return false }
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = ["--version"]
        var env = ProcessInfo.processInfo.environment; env["PATH"] = LoginPath.value; p.environment = env
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else { return false }
        if done.wait(timeout: .now() + 8) == .timedOut { p.terminate(); return false }
        return p.terminationStatus == 0
    }
}
