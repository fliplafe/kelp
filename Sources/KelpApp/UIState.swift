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
    }
}
