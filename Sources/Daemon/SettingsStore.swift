import Foundation
import Core

/// `settings.json` in the Kelp home: one flat object with dotted keys (VS Code style).
/// Hand edits are picked up by `reloadIfChanged`; a file that doesn't parse is ignored and the last good settings stay.
final class SettingsStore: @unchecked Sendable {   // values and mtime under lock
    let url: URL
    private let lock = NSLock()
    private var values: [String: JSONValue] = [:]
    private var mtime: Date?

    /// config.json keys from before settings.json; read once, when settings.json doesn't exist yet.
    static let legacyKeys = ["hibernateMinutes": "sessions.hibernateMinutes", "keepAwake": "power.keepAwake", "profiles": "accounts.profiles"]

    init(root: URL) {
        url = root.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: url.path) { _ = reloadIfChanged(); return }
        let old = (try? Data(contentsOf: root.appendingPathComponent("config.json"))).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        for (k, v) in Self.legacyKeys { if let x = old?[k] { values[v] = x } }
        try? write()
    }

    var all: JSONValue { lock.withLock { .object(values) } }
    subscript(key: String) -> JSONValue? { lock.withLock { values[key] } }
    func number(_ key: String) -> Double? {
        switch self[key] {
        case .int(let i)?: Double(i)
        case .double(let d)?: d
        default: nil
        }
    }

    /// nil or .null removes the key.
    func set(_ key: String, _ value: JSONValue?) throws -> JSONValue {
        try lock.withLock {
            // A hand edit saved since the last poll is merged, not overwritten; a file that doesn't parse is the user's
            // work in progress, so nothing is written over it.
            if let d = try? Data(contentsOf: url) {
                guard case .object(let onDisk)? = try? JSONDecoder().decode(JSONValue.self, from: d) else {
                    throw RPCError.invalidParams("settings.json has an error, so the change wasn't saved. Fix the file (or remove it) and try again.")
                }
                values = onDisk
            }
            values[key] = value == .null ? nil : value
            try write()
            return .object(values)
        }
    }

    /// true when the file changed on disk and parsed.
    func reloadIfChanged() -> Bool {
        lock.withLock {
            let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            guard m != mtime else { return false }
            mtime = m
            guard let d = try? Data(contentsOf: url), case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: d) else { return false }
            values = o
            return true
        }
    }

    /// Caller holds the lock (or is init).
    private func write() throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (e.encode(JSONValue.object(values)) + Data("\n".utf8)).write(to: url, options: .atomic)
        mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date   // our own write isn't a hand edit
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
