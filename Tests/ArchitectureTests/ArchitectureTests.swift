import Foundation
import Testing

// The rules in docs/architecture.md, read from the sources. Each number is a ceiling that only goes down: when a change brings a
// count under it, lower it to the new count in the same commit, so nothing creeps back.

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Every .swift file under these folders (relative to the repo), with its text.
private func sources(_ dirs: [String]) -> [(path: String, text: String)] {
    dirs.flatMap { dir -> [(path: String, text: String)] in
        let base = root.appendingPathComponent(dir)
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "swift" }.compactMap { u in
            (try? String(contentsOf: u, encoding: .utf8)).map { (dir + u.path.dropFirst(base.path.count), $0) }
        }
    }
}

private func matches(_ pattern: String, in dirs: [String]) throws -> [String] {
    let re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    return sources(dirs).flatMap { f in
        re.matches(in: f.text, range: NSRange(f.text.startIndex..., in: f.text)).map { m in
            "\(f.path):\(f.text[..<(Range(m.range, in: f.text)?.lowerBound ?? f.text.startIndex)].filter { $0 == "\n" }.count + 1)"
        }
    }
}

/// The app and the CLI name a method by its `RPCMethod` type: with a string and hand-built params, a renamed field still
/// compiles and only breaks when it runs.
@Test func theAppAndTheCLICallTheDaemonThroughItsTypes() throws {
    let app = try matches(#"\b(call|tryCall|notify)\(\s*""#, in: ["Sources/KelpApp"])
    let cli = try matches(#"\b(call|tryCall|notify)\(\s*""#, in: ["Sources/kelp"])
    #expect(app.count <= 0, "string-named calls in KelpApp: \(app)")
    #expect(cli.count <= 0, "string-named calls in the kelp CLI: \(cli)")
}

/// One way to the daemon, through AppModel: `call` (a banner), `tryCall` / `get` (the panel's error state) or `quiet`
/// (decorations, which say so). `try?` around a call turned a failure into an empty list; the raw client skipped all of it.
/// AppModel.swift itself is the way (it also manages the connection), so it isn't counted.
@Test func daemonErrorsAreNotSwallowed() throws {
    func outside(_ found: [String]) -> [String] { found.filter { !$0.hasPrefix("Sources/KelpApp/AppModel.swift:") } }
    let swallowed = outside(try matches(#"try\? await [^=\n]*\.(call|get|tryCall)\("#, in: ["Sources/KelpApp"]))
    let raw = outside(try matches(#"\bclient\??\.call\(|\bc\??\.call\("#, in: ["Sources/KelpApp"]))
    #expect(swallowed == [], "try? around a call: \(swallowed)")
    #expect(raw == [], "the client called directly: \(raw)")
}

/// The app reads the daemon's records as Core's types: running git, gh, the agents' files and the daemon itself is the
/// daemon's job. (Package.swift enforces it too; this says why when someone adds the dependency back.)
@Test func theAppDoesNotImportTheDaemonsLibraries() {
    let banned = ["Daemon", "GitKit", "Integrations", "AgentData", "LSPKit"]
    let found = sources(["Sources/KelpApp"]).filter { f in banned.contains { f.text.hasPrefix("import \($0)\n") || f.text.contains("\nimport \($0)\n") } }
    #expect(found.map(\.path) == [])
}

/// The shell knows tabs as `TabContent`: a contributed tab's own type anywhere outside `Builtins/` (the window, the editor
/// area, the app delegate…) is a feature reached around the contribution points. The types are read from the sources:
/// every `TabContent` / `SavableTab` declared in `Builtins/` or `Extensions/`.
@Test func theShellKnowsTabsOnlyAsContributions() throws {
    let declared = try NSRegularExpression(pattern: #"(?:class|struct) (\w+)\s*:[^{]*\b(?:TabContent|SavableTab)\b"#)
    var tabs: [String: String] = [:]   // type → the file that declares it (which may name itself)
    for f in sources(["Sources/KelpApp/Builtins", "Sources/KelpApp/Extensions"]) {
        for m in declared.matches(in: f.text, range: NSRange(f.text.startIndex..., in: f.text)) {
            if let r = Range(m.range(at: 1), in: f.text) { tabs[String(f.text[r])] = f.path }
        }
    }
    #expect(tabs.keys.contains("FileTab") && tabs.keys.contains("ExtViewTab"), "\(tabs.keys.sorted())")   // the scan finds them
    let cast = try NSRegularExpression(pattern: #"(?:as[?!]?|is) ("# + tabs.keys.joined(separator: "|") + #")\b"#)
    var found: [String] = []
    for f in sources(["Sources/KelpApp"]) where !f.path.hasPrefix("Sources/KelpApp/Builtins/") {
        for m in cast.matches(in: f.text, range: NSRange(f.text.startIndex..., in: f.text)) {
            guard let r = Range(m.range(at: 1), in: f.text), tabs[String(f.text[r])] != f.path else { continue }
            found.append("\(f.path): \(f.text[r])")
        }
    }
    #expect(found == [])
}

/// The shell (everything outside `Builtins/`) reaches a built-in through what it contributed (its `TabProvider`, commands,
/// panels…), never by its type: a built-in named there is one the shell can't do without. The names are read from the
/// sources: every type a file in `Builtins/` declares at its top level, other than private ones (nested types are the
/// feature's own). `Builtins` itself is the list the registry loads.
@Test func theShellNamesNoBuiltin() throws {
    let declared = try NSRegularExpression(
        pattern: #"^(?:@\w+(?:\([^)\n]*\))?\s+)*(?:(?:public|internal|final|nonisolated)\s+)*(?:class|struct|enum|protocol|actor|typealias)\s+([A-Z]\w*)"#,
        options: [.anchorsMatchLines])
    var names = Set<String>()
    for f in sources(["Sources/KelpApp/Builtins"]) {
        for m in declared.matches(in: f.text, range: NSRange(f.text.startIndex..., in: f.text)) {
            if let r = Range(m.range(at: 1), in: f.text) { names.insert(String(f.text[r])) }
        }
    }
    names.remove("Builtins")
    #expect(names.contains("SessionTab") && names.contains("PaneView"), "\(names.sorted())")   // the scan finds them
    let named = try NSRegularExpression(pattern: #"\b("# + names.sorted().joined(separator: "|") + #")\b"#)
    var found: [String] = []
    for f in sources(["Sources/KelpApp"]) where !f.path.hasPrefix("Sources/KelpApp/Builtins/") {
        let code = codeOnly(f.text)
        for m in named.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let r = Range(m.range(at: 1), in: code) else { continue }
            found.append("\(f.path):\(code[..<r.lowerBound].filter { $0 == "\n" }.count + 1): \(code[r])")
        }
    }
    #expect(found == [], "built-ins named outside Builtins/")
}

/// What the shell asks of every tab stays short: a question only one kind of tab answers is that tab's own (its provider's
/// menu, its badge), not one more requirement every tab carries a "not this one" default for.
@Test func tabContentAsksLittle() throws {
    let text = try #require(sources(["Sources/KelpApp/Editor"]).first { $0.path.hasSuffix("/TabContent.swift") }?.text)
    let start = try #require(text.range(of: "protocol TabContent: AnyObject {"))
    let end = try #require(text.range(of: "\n}", range: start.upperBound..<text.endIndex))
    let body = text[start.upperBound..<end.lowerBound]
    let requirements = body.split(separator: "\n").filter { l in
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("var ") || t.hasPrefix("func ")
    }
    #expect(requirements.count <= 15, "\(requirements)")
}

/// A Swift file's code without its comments and string literals (their words could be any name); lines stay where they were.
private func codeOnly(_ s: String) -> String {
    var out = "", i = s.startIndex
    func skip(to end: String.Index) { out += s[i..<end].filter { $0 == "\n" }; i = end }
    while i < s.endIndex {
        let rest = s[i...]
        if rest.hasPrefix("//") { skip(to: rest.firstIndex(of: "\n") ?? s.endIndex) }
        else if rest.hasPrefix("/*") { skip(to: rest.range(of: "*/")?.upperBound ?? s.endIndex) }
        else if rest.hasPrefix("\"\"\"") { skip(to: rest.dropFirst(3).range(of: "\"\"\"")?.upperBound ?? s.endIndex) }
        else if rest.first == "\"" {
            var j = rest.index(after: rest.startIndex)
            while j < s.endIndex, s[j] != "\"", s[j] != "\n" { j = s.index(j, offsetBy: s[j] == "\\" && s.index(after: j) < s.endIndex ? 2 : 1) }
            skip(to: j < s.endIndex && s[j] == "\"" ? s.index(after: j) : j)
        } else { out.append(s[i]); i = s.index(after: i) }
    }
    return out
}

/// The daemon's events reach the app as their types (`RPCClient.onEvent`, decoded once on the client's reader thread):
/// the app doesn't switch on their names or decode them from JSON on the main thread.
@Test func theAppTakesEventsByType() throws {
    #expect(try matches(#"onNotification|case [A-Z]\w*\.name\b|\.decode\(\w*(Event|Session|Repo|Worktree)\.self"#, in: ["Sources/KelpApp"]) == [])
}

/// Questions are sheets that are awaited: a nested modal loop (runModal for a sheet) runs every timer, event and task of
/// the app inside it, and a semaphore on the main thread stops them all. (The hang watcher's semaphore is on a thread of
/// its own: it's what notices a stuck main thread.)
@Test func theMainThreadNeverWaitsInALoopOfItsOwn() throws {
    #expect(try matches(#"runAsSheet|NSApp\.runModal\(for"#, in: ["Sources/KelpApp"]) == [])
    #expect(try matches(#"DispatchSemaphore"#, in: ["Sources/KelpApp"]).filter { !$0.hasPrefix("Sources/KelpApp/DevAids.swift") } == [])
    // Until a `.terminateLater` reply AppKit runs a modal mode in which the main actor's tasks don't run: an async
    // question asked from there never shows (quitting with an unsaved file closed nothing and asked nothing).
    #expect(try matches(#"\.terminateLater"#, in: ["Sources/KelpApp"]) == [])
}

/// The daemon starts every program (an extension's command, a formatter, a notebook run, an agent's --version:
/// `process.run`), with its time limits, its process-tree kill and its trust checks; the app starts none. Two exceptions:
/// the app launching kelpd itself, and DevAids' `sample` of a stuck main thread (a developer's tool). Core's helpers that
/// start one count too: LoginPath runs the login shell (the app asks the daemon: `process.which`), the library's index and
/// download run curl and tar.
@Test func theAppStartsNoPrograms() throws {
    let allowed = ["Sources/KelpApp/AppModel.swift", "Sources/KelpApp/DevAids.swift"]
    let found = try matches(#"\bProcess\(\)|\bSubprocess\.|posix_spawn|\bNSTask\b|\bLoginPath\.|\bfetchExtension\(|\blibrary\(index"#, in: ["Sources/KelpApp"])
        .filter { f in !allowed.contains { f.hasPrefix($0 + ":") } }
    #expect(found == [])
    // A new Core helper that starts a program: add what the app could call to the pattern above.
    let starters = Set(try matches(#"\bProcess\(\)|\bSubprocess\.run\("#, in: ["Sources/Core"]).map { String($0.split(separator: ":")[0]) })
    #expect(starters == ["Sources/Core/Subprocess.swift", "Sources/Core/LoginPath.swift", "Sources/Core/Library.swift"])
}

/// The app doesn't ask the daemon again and again: views watch (`watch.start`) and the daemon pushes what changed.
/// A clock left in the app is the app's own, each listed with why; a new one that polls the daemon belongs in a watch.
@Test func theAppDoesntPollTheDaemon() throws {
    let clocks: [String: String] = [
        "AppDelegate.swift": "a finished agent counts as read after a second on screen; a 30 ms wait for the window at launch",
        "Sidebar/SidebarController.swift": "relative times on the rows (\"now\" becomes \"1m\")",
        "AppModel.swift": "connecting: waiting for the socket, retries and backoff",
        "Notifier.swift": "a notification's summary waits a moment for the agent's last line",
        "Shell/Latency.swift": "\"Loading…\" only once a wait is long enough to notice",
        "Builtins/Agents/UsageTab.swift": "a \"still reading\" hint after 3 s",
        "Builtins/Files/FileTab.swift": "typing settles before the language server hears it",
        "Builtins/Files/MarkdownTab.swift": "typing settles before the preview renders again",
        "Extensions/ExtListView.swift": "an extension's own refresh interval for its command's list"
    ]
    let all = try matches(#"repeats: true|Task\.sleep\("#, in: ["Sources/KelpApp"])
    let found = all.filter { m in !clocks.keys.contains { m.hasPrefix("Sources/KelpApp/" + $0 + ":") } }
    #expect(found == [], "a clock asking the daemon: watch a topic instead (WatchTopic)")
    let gone = clocks.keys.filter { k in !all.contains { $0.hasPrefix("Sources/KelpApp/" + k + ":") } }
    #expect(gone == [], "listed, but its clock is gone: take it off the list")
}

/// The daemon is its connections and the services it puts together; what each service keeps is its own, under its own
/// locks, and a service is given what it uses instead of reaching back into `Daemon`. Counted: `Daemon`'s stored
/// properties, the extensions that add to it from other files, and state kept outside any instance (a file-scope value
/// or a static object other than a logger), which every daemon in one process (tests) would share.
@Test func theDaemonKeepsItsStateInItsServices() throws {
    let daemon = try #require(sources(["Sources/Daemon"]).first { $0.path == "Sources/Daemon/Daemon.swift" })
    let stored = try NSRegularExpression(pattern: #"^    (?:public |private )?let "#, options: [.anchorsMatchLines])
        .numberOfMatches(in: daemon.text, range: NSRange(daemon.text.startIndex..., in: daemon.text))
    let extensions = try matches(#"^extension Daemon\b"#, in: ["Sources/Daemon"])
    let shared = try matches(#"^(?:private |fileprivate |public )?(?:let|var) \w+|^\s+(?:private |public )?static let \w+ = (?!Logger\()[A-Z]\w*(?:<[^>]*>)?\("#,
                             in: ["Sources/Daemon"])
    #expect(stored <= 14, "Daemon's stored properties: \(stored)")
    #expect(extensions.count <= 23, "extensions of Daemon: \(extensions)")
    #expect(shared.count <= 0, "state outside an instance: \(shared)")
    // A service gets what it uses at init: one that names Daemon reaches back into everything.
    let services = ["AgentUsage.swift", "UsageProbe.swift", "AgentConfig.swift", "Forges.swift", "Workspaces.swift", "Watches.swift",
                    "Sessions.swift", "SessionLaunch.swift", "Retention.swift"]
    let named = sources(["Sources/Daemon"]).filter { f in services.contains { f.path.hasSuffix("/" + $0) } && codeOnly(f.text).contains("Daemon") }
    #expect(named.map(\.path) == [])
    #expect(sources(["Sources/Daemon"]).filter { f in services.contains { f.path.hasSuffix("/" + $0) } }.count == services.count)
}

/// A project's files are read, written, watched, moved and made by the daemon (`files.*`, `WatchTopic.file(s)`), with a
/// tab's rules and the same way for a project on another machine. What the app still touches itself is listed with
/// why: its own folders, a viewer's bytes, whether a path is there. Nothing else does.
@Test func theAppDoesntTouchProjectFiles() throws {
    let own: [String: String] = [
        "AgentIcons.swift": "agents' icons, cached in Kelp's home",
        "AppModel.swift": "why kelpd didn't start, in Kelp's home",
        "DevAids.swift": "snapshots for tests",
        "RemoteSheet.swift": "the hosts in ~/.ssh/config",
        "CloneSheet.swift": "whether the folder new projects go in is there",
        "Settings/IconTheme.swift": "an icon theme an extension brings",
        "Settings/SettingsWindow.swift": "an extension's own folder",
        "Extensions/Registry.swift": "extensions' folders, Kelp's own",
        "Extensions/DeclarativeExtension.swift": "an extension's manifest",
        "Extensions/ExtensionReview.swift": "an extension's manifest, before it's installed",
        "Extensions/AgentSkills.swift": "the skills Kelp gives agents, in Kelp's home",
        "Shell/Help.swift": "the guide, written to Kelp's home",
        "Shell/WorkbenchActions.swift": "a dropped or linked path: a file, a folder, or nothing",
        "Sidebar/ProjectIcon.swift": "a project's icon, shown",
        "Sidebar/SidebarCell.swift": "a project folder that's gone",
        "Sidebar/SidebarActions.swift": "a project folder that's gone",
        "Builtins/Agents/PathPreview.swift": "a path a terminal printed is a file, before it's a link",
        "Builtins/Browser/BrowserTab.swift": "a local page, shown: it reloads as its folder changes; a page's screenshot",
        "Builtins/Files/Preview.swift": "an image's bytes, shown"
    ]
    let all = try matches(#"FileManager\.default\.(contents|createFile|moveItem|trashItem|copyItem|removeItem|createDirectory|fileExists|isWritableFile)"#
        + #"|FileWatcher\(|String\(contentsOf|Data\(contentsOf|\.write\(to(File)?:|\bstat\([^()]*&"#, in: ["Sources/KelpApp"])
    let left = all.filter { m in !own.keys.contains { m.hasPrefix("Sources/KelpApp/" + $0 + ":") } }
    #expect(left == [], "a project's files touched by the app: go through the daemon (files.*)")
    let gone = own.keys.filter { k in !all.contains { $0.hasPrefix("Sources/KelpApp/" + k + ":") } }
    #expect(gone == [], "listed, but it touches no file now: take it off the list")
}

/// The app's state is handed down from the one `AppModel` (it owns the workbench, the settings and the extensions):
/// the window to its panels and editor areas, the registry to the built-ins' contributions, and on to their views. A
/// view that reaches `X.shared` instead can only ever show the one app, and its tests have to take turns
/// (`SharedAppModel`). Only the app's start (main.swift, AppDelegate) and DevAids reach it; the rest has a ceiling per
/// folder, one line each.
@Test func theAppIsHandedItsModel() throws {
    let ceilings: [String: Int] = [
        "": 74,
        "Builtins/Agents": 1,
        "Extensions": 20,
        "Settings": 24,
        "Shell": 118,
        "Sidebar": 1
    ]
    let starts = ["main.swift", "AppDelegate.swift", "DevAids.swift"]
    var found: [String: Int] = [:]
    let shared = try NSRegularExpression(pattern: #"\b(AppModel|Workbench|SettingsStore|ExtensionRegistry)\.shared\b"#)
    for f in sources(["Sources/KelpApp"]) where !starts.contains(where: { f.path == "Sources/KelpApp/" + $0 }) {
        let code = codeOnly(f.text)
        let n = shared.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
        guard n > 0 else { continue }
        let parts = f.path.dropFirst("Sources/KelpApp/".count).split(separator: "/").dropLast()
        found[parts.prefix(parts.first == "Builtins" ? 2 : 1).joined(separator: "/"), default: 0] += n
    }
    for (folder, n) in found.sorted(by: { $0.key < $1.key }) {
        #expect(n <= ceilings[folder, default: 0], "X.shared in \(folder.isEmpty ? "KelpApp's root" : folder): \(n), take it from what's handed down")
    }
    #expect(ceilings.allSatisfy { found[$0.key, default: 0] >= $0.value },
            "a folder's ceiling is above its count: lower it to \(found)")
    // Singletons of the app's own: no new ones (each is one more thing a second app would share).
    let singletons = try matches(#"^\s*static let shared = "#, in: ["Sources/KelpApp"])
    #expect(singletons.count <= 11, "\(singletons)")
}
