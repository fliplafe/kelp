import Foundation
import os
import Core

/// `settings.json` in the Kelp home: one flat object with dotted keys (VS Code style).
/// Hand edits are picked up by `reloadIfChanged`; a file that doesn't parse is ignored and the last good settings stay.
final class SettingsStore: Sendable {
    let url: URL
    /// The settings and the file's date as last read or written, held only to copy them: the ticker reads settings twice
    /// a second, and must not wait on a disk.
    private let state = OSAllocatedUnfairLock<(values: [String: JSONValue], mtime: Date?)>(initialState: ([:], nil))
    /// The file's reads and writes, one at a time (a set's read, merge and write stay together).
    let file = NSLock()

    /// config.json keys from before settings.json; read once, when settings.json doesn't exist yet.
    static let legacyKeys = ["hibernateMinutes": "sessions.hibernateMinutes", "keepAwake": "power.keepAwake", "profiles": "accounts.profiles"]

    init(root: URL) {
        url = root.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: url.path) { _ = reloadIfChanged(); return }
        let old = (try? Data(contentsOf: root.appendingPathComponent("config.json"))).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        var values: [String: JSONValue] = [:]
        for (k, v) in Self.legacyKeys { if let x = old?[k] { values[v] = x } }
        file.withLock { _ = Log.store.attempt("writing settings.json from config.json") { try write(values) } }
    }

    var values: [String: JSONValue] { state.withLock { $0 }.values }
    var all: JSONValue { .object(values) }
    subscript(key: String) -> JSONValue? { state.withLock { $0 }.values[key] }
    func number(_ key: String) -> Double? { self[key]?.number }

    /// nil or .null removes the key.
    func set(_ key: String, _ value: JSONValue?) throws -> [String: JSONValue] {
        try file.withLock {
            // A hand edit saved before this is merged, not overwritten; a file that doesn't parse is the user's work in
            // progress, so nothing is written over it. One saved while this merged (an editor's save) is read again.
            for _ in 0..<3 {
                let seen = modified()
                var values = self.values
                if let d = try? Data(contentsOf: url) {
                    guard case .object(let onDisk)? = try? JSONDecoder().decode(JSONValue.self, from: d) else {
                        throw RPCError.invalidParams("settings.json has an error, so the change wasn't saved. Fix the file (or remove it) and try again.")
                    }
                    values = onDisk
                }
                values[key] = value == .null ? nil : value
                guard modified() == seen else { continue }
                try write(values)
                return values
            }
            throw RPCError.invalidParams("settings.json keeps changing, so the change wasn't saved. Try again.")
        }
    }

    /// true when the file changed on disk and parsed. After a set writing now has finished: a hand edit saved meanwhile
    /// is read then (no later event may come to read it).
    func reloadIfChanged() -> Bool {
        file.lock()
        defer { file.unlock() }
        let m = modified()
        guard m != state.withLock({ $0.mtime }) else { return false }
        let o: [String: JSONValue]? = (try? Data(contentsOf: url)).flatMap {
            if case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: $0) { o } else { nil }
        }
        state.withLock { st in st.mtime = m; if let o { st.values = o } }
        return o != nil
    }

    /// The date of the file a symlink points at: the link's own never changes on an edit.
    private func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
    }

    /// Under `file`; the values change only once they're on disk.
    private func write(_ values: [String: JSONValue]) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // To where a symlink points (settings.json kept in a dotfiles repo): an atomic write would replace the link itself.
        try (e.encode(JSONValue.object(values)) + Data("\n".utf8)).write(to: url.resolvingSymlinksInPath(), options: .atomic)
        let m = modified()   // our own write isn't a hand edit
        state.withLock { $0 = (values, m) }
    }
}

/// The settings as clients hear of them (`event.settings`): as they are when it's their turn, one change after another,
/// so two sets close together can't announce themselves the wrong way round (the app takes each event as the whole of
/// the settings). Keep Mac Awake follows at once.
final class SettingsEvents: Sendable {
    let store: SettingsStore
    private let clients: Clients, sessions: Sessions
    private let queue = DispatchQueue(label: "kelp.settings-events")

    init(store: SettingsStore, clients: Clients, sessions: Sessions) {
        self.store = store
        self.clients = clients
        self.sessions = sessions
    }

    func changed() {
        queue.async { [self] in
            clients.notify(SettingsEvent(settings: store.values))
            sessions.applyKeepAwake()
        }
    }

    /// Hand edits of settings.json, as they're saved: FSEvents on the folder of the file it resolves to (a symlink into
    /// someone's dotfiles too). Limit: a symlink pointed elsewhere later is followed after the daemon restarts.
    private let watcher = OSAllocatedUnfairLock<FileWatcher?>(initialState: nil)
    func watch() {
        let file = store.url.resolvingSymlinksInPath(), name = "/" + file.lastPathComponent
        let fw = FileWatcher(root: file.deletingLastPathComponent().path, deliver: queue) { [weak self] paths in
            guard let self, paths.contains(where: { $0.hasSuffix(name) }), store.reloadIfChanged() else { return }
            changed()
        }
        if fw == nil { Log.store.error("settings.json isn't watched: hand edits are read when the daemon restarts") }
        let old = watcher.withLock { w in defer { w = fw }; return w }
        _ = old   // stopped here, off the lock (its deinit waits on its own queue)
    }
    func stopWatching() {
        let old = watcher.withLock { w in defer { w = nil }; return w }
        _ = old
    }
}

extension SettingsGet: Handled { func handle(_ settings: SettingsStore) throws -> [String: JSONValue] { settings.values } }
extension SettingsSet: Handled {
    /// A colour dragged or a stepper held sends these quickly: the last one sent is the one that stays.
    static var inOrder: Bool { true }
    func handle(_ settings: SettingsEvents) throws -> [String: JSONValue] {
        let all = try settings.store.set(key, value)
        settings.changed()
        return all
    }
}
