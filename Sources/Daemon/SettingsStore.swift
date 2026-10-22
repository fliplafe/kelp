import Foundation
import os
import Core

/// `settings.json` in the Kelp home: one flat object with dotted keys (VS Code style).
/// Hand edits are picked up by `reloadIfChanged`; a file that doesn't parse is ignored and the last good settings stay.
final class SettingsStore: Sendable {
    let url: URL
    /// The settings and the file's date as last read or written; reads and writes of the file happen under it too.
    private let state = OSAllocatedUnfairLock<(values: [String: JSONValue], mtime: Date?)>(initialState: ([:], nil))

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

    var values: [String: JSONValue] { state.withLock { $0 }.values }
    var all: JSONValue { .object(values) }
    subscript(key: String) -> JSONValue? { state.withLock { $0 }.values[key] }
    func number(_ key: String) -> Double? { self[key]?.number }

    /// nil or .null removes the key.
    func set(_ key: String, _ value: JSONValue?) throws -> [String: JSONValue] {
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
            return st.values
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
    /// The settings as they are when it's their turn, one change after another: two sets close together can't announce
    /// themselves the wrong way round (the app takes each event as the whole of the settings).
    func settingsChanged() {
        settingsEvents.async { [self] in
            notify(SettingsEvent(settings: settings.values))
            sessions.applyKeepAwake()
        }
    }

    /// From the ticker: hand edits of settings.json.
    func pollSettings() {
        if settings.reloadIfChanged() { settingsChanged() }
    }
}

extension SettingsGet: Handled { func handle(_ settings: SettingsStore) throws -> [String: JSONValue] { settings.values } }
extension SettingsSet: Handled {
    /// A colour dragged or a stepper held sends these quickly: the last one sent is the one that stays.
    static var inOrder: Bool { true }
    func handle(_ d: Daemon) throws -> [String: JSONValue] {
        let all = try d.settings.set(key, value)
        d.settingsChanged()
        return all
    }
}
