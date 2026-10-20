import Foundation
import Core

/// What the app restores that names the daemon's records — each workspace's layout (`layout/<id>`), the sidebar's
/// order, pins and folds, the last workspace — lives in the daemon's database (`state.*`), like Zed's workspace DB:
/// every KELP_HOME has its own, and removing a workspace takes its layout with it. Per-Mac view preferences stay in
/// UserDefaults. Loaded on connect, before the window restores anything; reads are synchronous, writes go to the daemon.
@MainActor
enum UIState {
    private static var values: [String: JSONValue] = [:]

    /// nil deletes. Without a daemon it's kept for this run only.
    static subscript(key: String) -> JSONValue? {
        get { values[key] }
        set {
            guard values[key] != newValue else { return }
            values[key] = newValue
            AppModel.shared.client?.notify(StateSet(key: key, value: newValue))
        }
    }
    static func strings(_ key: String) -> [String] { values[key]?.array?.compactMap(\.string) ?? [] }

    /// A daemon too old for `state.*` leaves it empty.
    static func load(_ c: RPCClient) async {
        guard case .object(let all)? = try? await c.call(StateGet(prefix: "")) else { return }
        values = all
        await importDefaults(c)
    }

    /// Kelp kept these in UserDefaults until 2026-10. Only the user's own daemon takes them over (a KELP_HOME is a test
    /// or another setup), each key once: what the daemon already has wins.
    private static func importDefaults(_ c: RPCClient) async {
        guard ProcessInfo.processInfo.environment["KELP_HOME"] == nil else { return }
        let d = UserDefaults.standard
        var keys = ["sidebar.order": "sidebar.order", "sidebar.pinned": "sidebar.pinned", "sidebar.collapsed": "sidebar.collapsed",
                    "lastWorkspace": "workbench.lastWorkspace"]
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("layout3.") { keys[k] = "layout/" + k.dropFirst(8) }
        for (old, key) in keys {
            guard let v = d.object(forKey: old) else { continue }
            let value = (v as? Data).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                ?? (v as? [String]).map { .array($0.map(JSONValue.string)) } ?? (v as? String).map(JSONValue.string)
            if values[key] == nil, let value {
                guard (try? await c.call(StateSet(key: key, value: value))) != nil else { continue }
                values[key] = value
            }
            d.removeObject(forKey: old)
        }
    }
}
