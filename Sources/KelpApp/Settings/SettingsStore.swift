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

    func load() async {
        if let o = await AppModel.shared.call(SettingsGet()) { apply(o) }   // else a banner: what's shown may not be settings.json
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
    func number(_ key: String) -> Double? { value(key)?.number }

    /// Shows a value without saving it (the palette trying themes on); `set` keeps one, `preview(key, saved)` goes back.
    func preview(_ key: String, _ v: JSONValue?) {
        var next = values; next[key] = v
        apply(next)
    }

    func set(_ key: String, _ v: JSONValue?) {
        var next = values; next[key] = v
        apply(next)   // optimistic; the daemon's echo confirms
        Task {
            // Not saved: say so and show what settings.json really holds again, instead of a value that reverts later.
            if let error = await AppModel.shared.tryCall(SettingsSet(key: key, value: v)).error {
                Banner.show(String(localized: "Couldn't change “\(key)”: \(error)"), style: .error)
                await load()
            }
        }
    }
}
