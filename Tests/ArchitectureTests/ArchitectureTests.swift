import Foundation
import Testing

// The rules in AGENTS.md, read from the sources. Each number is a ceiling that only goes down: when a change brings a
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
    let banned = ["Daemon", "GitKit", "Integrations", "AgentData"]
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
