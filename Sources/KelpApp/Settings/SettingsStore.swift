import Foundation
import Observation
import Core

/// ~/.kelp/settings.json, owned by the daemon so the CLI and agents can change it too.
/// Reads are synchronous from the last copy; writes go through the daemon and come back as `event.settings`.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()
    private(set) var values: [String: JSONValue] = [:]
    @ObservationIgnored private var local = false   // daemon predates settings.* (keeps the UI usable)

    func load() async {
        guard let c = AppModel.shared.client else { return }
        do {
            if case .object(let o) = try await c.call("settings.get") { apply(o) }
        } catch let e as RPCError where e.code == RPCError.methodNotFound.code {
            local = true
            if let d = UserDefaults.standard.data(forKey: "settings.local"), case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: d) { apply(o) }
        } catch {}
        migrateDefaults()
    }

    func apply(_ o: [String: JSONValue]) {
        guard o != values else { return }
        // The skills only depend on their switches: don't rewrite their files (on main) for every other setting.
        let skills = { (d: [String: JSONValue]) in d.filter { $0.key.hasPrefix("agents.skills.") } }
        let skillsChanged = values.isEmpty || skills(o) != skills(values)
        values = o
        ThemeManager.shared.apply()
        if skillsChanged { AgentSkills.write() }
        if !ExtensionRegistry.shared.extensions.isEmpty, ExtensionRegistry.disabled(o["extensions.disabled"]) != ExtensionRegistry.shared.disabledLoaded {
            ExtensionRegistry.shared.reload()
        }
    }

    /// A setting's value, or the default its spec declares.
    func value(_ key: String) -> JSONValue? {
        if let v = values[key] { return v }
        for s in ExtensionRegistry.shared.all.settings { if let spec = s.specs.first(where: { $0.key == key }) { return spec.default } }
        return nil
    }
    func string(_ key: String) -> String? { value(key)?.string }
    func bool(_ key: String) -> Bool? { value(key)?.bool }
    func number(_ key: String) -> Double? {
        switch value(key) {
        case .double(let d)?: d
        case .int(let i)?: Double(i)
        default: nil
        }
    }

    /// Shows a value without saving it (the palette trying themes on); `set` keeps one, `preview(key, saved)` goes back.
    func preview(_ key: String, _ v: JSONValue?) {
        var next = values; next[key] = v
        apply(next)
    }

    func set(_ key: String, _ v: JSONValue?) {
        var next = values; next[key] = v
        apply(next)   // optimistic; the daemon's echo confirms
        if local {
            UserDefaults.standard.set(try? JSONEncoder().encode(JSONValue.object(values)), forKey: "settings.local"); return
        }
        Task {
            // Not saved: say so and show what settings.json really holds again, instead of a value that reverts later.
            do {
                guard let c = AppModel.shared.client else { throw RPCError.internalError(String(localized: "Kelp's background service isn't running.")) }
                _ = try await c.call("settings.set", .obj(["key": .string(key), "value": v ?? .null]))
            } catch {
                Banner.show(String(localized: "Couldn't change “\(key)”: \((error as? RPCError)?.message ?? error.localizedDescription)"), style: .error)
                await load()
            }
        }
    }

    /// Preferences the app used to keep in UserDefaults move to settings.json once.
    private func migrateDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "settings.migrated") else { return }
        d.set(true, forKey: "settings.migrated")
        let map = ["defaultAgent": "agents.default", "branchPrefix": "git.branchPrefix", "lspEnabled": "editor.lsp"]
        for (old, new) in map where values[new] == nil {
            if let s = d.string(forKey: old) { set(new, .string(s)) } else if let b = d.object(forKey: old) as? Bool { set(new, .bool(b)) }
        }
    }
}
