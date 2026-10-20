import Foundation
import Core

/// `settings.json` in the Kelp home: one flat object with dotted keys (VS Code style).
/// Hand edits are picked up by `reloadIfChanged`; a file that doesn't parse is ignored and the last good settings stay.
final class SettingsStore: Sendable {
    let url: URL
    /// The settings and the file's date as last read or written; reads and writes of the file happen under it too.
    private let state = Locked<(values: [String: JSONValue], mtime: Date?)>(([:], nil))

    /// config.json keys from before settings.json; read once, when settings.json doesn't exist yet.
    static let legacyKeys = ["hibernateMinutes": "sessions.hibernateMinutes", "keepAwake": "power.keepAwake", "profiles": "accounts.profiles"]

    init(root: URL) {
        url = root.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: url.path) { _ = reloadIfChanged(); return }
        let old = (try? Data(contentsOf: root.appendingPathComponent("config.json"))).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        state.withLock { st in
            for (k, v) in Self.legacyKeys { if let x = old?[k] { st.values[v] = x } }
            try? write(&st)
        }
    }

    var all: JSONValue { .object(state.current.values) }
    subscript(key: String) -> JSONValue? { state.current.values[key] }
    func number(_ key: String) -> Double? { self[key]?.number }

    /// nil or .null removes the key.
    func set(_ key: String, _ value: JSONValue?) throws -> JSONValue {
        try state.withLock { st in
            // A hand edit saved since the last poll is merged, not overwritten; a file that doesn't parse is the user's
            // work in progress, so nothing is written over it.
            if let d = try? Data(contentsOf: url) {
                guard case .object(let onDisk)? = try? JSONDecoder().decode(JSONValue.self, from: d) else {
                    throw RPCError.invalidParams("settings.json has an error, so the change wasn't saved. Fix the file (or remove it) and try again.")
                }
                st.values = onDisk
            }
            st.values[key] = value == .null ? nil : value
            try write(&st)
            return .object(st.values)
        }
    }

    /// true when the file changed on disk and parsed.
    func reloadIfChanged() -> Bool {
        state.withLock { st in
            let m = modified()
            guard m != st.mtime else { return false }
            st.mtime = m
            guard let d = try? Data(contentsOf: url), case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: d) else { return false }
            st.values = o
            return true
        }
    }

    /// The date of the file a symlink points at: the link's own never changes on an edit.
    private func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
    }

    /// Inside `state.withLock`.
    private func write(_ st: inout (values: [String: JSONValue], mtime: Date?)) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // To where a symlink points (settings.json kept in a dotfiles repo): an atomic write would replace the link itself.
        try (e.encode(JSONValue.object(st.values)) + Data("\n".utf8)).write(to: url.resolvingSymlinksInPath(), options: .atomic)
        st.mtime = modified()   // our own write isn't a hand edit
    }
}

extension Daemon {
    func handleSettings(_ method: String, _ p: JSONValue) throws -> JSONValue? {
        switch method {
        case "settings.get": return settings.all
        case "settings.set":
            let all = try settings.set(try p.req("key"), p["value"])
            settingsChanged(all)
            return all
        // The current app still speaks these with the old config.json keys; drop once it uses settings.*.
        case "config.get":
            var o: [String: JSONValue] = [:]
            for (old, new) in SettingsStore.legacyKeys { o[old] = settings[new] }
            return .object(o)
        case "config.set":
            var all = settings.all
            if case .object(let o) = p { for (k, v) in o { if let key = SettingsStore.legacyKeys[k] { all = try settings.set(key, v) } } }
            settingsChanged(all)
            return try handleSettings("config.get", .null)
        default: return nil
        }
    }

    func settingsChanged(_ all: JSONValue) {
        notify("event.settings", .obj(["settings": all]))
        applyKeepAwake()
    }

    /// From the ticker: hand edits of settings.json.
    func pollSettings() {
        if settings.reloadIfChanged() { settingsChanged(settings.all) }
    }
}
