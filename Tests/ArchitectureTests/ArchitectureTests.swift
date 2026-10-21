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
    #expect(app.count <= 102, "string-named calls in KelpApp: \(app)")
    #expect(cli.count <= 35, "string-named calls in the kelp CLI: \(cli)")
}

/// A failed call says why (a banner, the panel's error state): `try?` turns it into an empty list or nothing at all.
@Test func daemonErrorsAreNotSwallowed() throws {
    let swallowed = try matches(#"try\? await [^=\n]*\.call\("#, in: ["Sources/KelpApp"])
    #expect(swallowed.count <= 52, "\(swallowed)")
}

/// The app reads the daemon's records as Core's types: running git, gh, the agents' files and the daemon itself is the
/// daemon's job. (Package.swift enforces it too; this says why when someone adds the dependency back.)
@Test func theAppDoesNotImportTheDaemonsLibraries() {
    let banned = ["Daemon", "GitKit", "Integrations", "AgentData"]
    let found = sources(["Sources/KelpApp"]).filter { f in banned.contains { f.text.hasPrefix("import \($0)\n") || f.text.contains("\nimport \($0)\n") } }
    #expect(found.map(\.path) == [])
}

/// The shell (window, editor area) knows tabs as `TabContent`: a built-in's own type there is a feature reached around
/// the contribution points.
@Test func theShellKnowsTabsOnlyAsContributions() throws {
    let casts = try matches(#"as\? (FileTab|SessionTab|UntitledTab|NotebookTab|MarkdownTab|BrowserTab)\b"#,
                        in: ["Sources/KelpApp/Shell", "Sources/KelpApp/Editor"])
    #expect(casts.count <= 6, "\(casts)")
}
