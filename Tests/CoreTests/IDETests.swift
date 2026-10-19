import Foundation
import Testing
@testable import Core

@Test func extensionGuideMatchesDocs() throws {
    let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/extensions.md")
    #expect(ExtensionGuide.markdown == (try String(contentsOf: doc, encoding: .utf8)), "regenerate Sources/Core/ExtensionGuide.swift from docs/extensions.md")
}

/// The starter's list command must print one JSON object per line using only stock tools.
@Test func scaffoldedExtensionWorks() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kx-\(UUID().uuidString.prefix(8))")
    let folder = try IDE.scaffoldExtension(id: "files", name: nil, description: "Top-level files", in: dir)
    #expect(try String(contentsOf: dir.appendingPathComponent("EXTENSIONS.md"), encoding: .utf8) == ExtensionGuide.markdown)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
    let m = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent("extension.json")))
    #expect(m["id"] == "files" && m["description"] == "Top-level files")
    let command = try #require(m["contributes"]?["panels"]?.array?.first?["list"]?["command"]?.string)

    let work = dir.appendingPathComponent("work"); try Paths.ensure(work)
    try "hi".write(to: work.appendingPathComponent("a b.txt"), atomically: true, encoding: .utf8)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", command]; p.currentDirectoryURL = work
    let out = Pipe(); p.standardOutput = out
    try p.run(); p.waitUntilExit()
    let rows = (String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").split(separator: "\n")
        .compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    #expect(rows == [.obj(["name": "./a b.txt", "size": 2])])

    #expect(throws: RPCError.self) { try IDE.scaffoldExtension(id: "files", name: nil, description: nil, in: dir) }   // exists
    #expect(!IDE.isValidExtensionID("Bad_ID") && !IDE.isValidExtensionID("..") && IDE.isValidExtensionID("docker.compose-2"))
}

@Test func openTargets() {
    #expect(IDE.uri(for: "https://x.dev/a", cwd: "/w") == "https://x.dev/a")
    #expect(IDE.uri(for: "a/b.swift", cwd: "/w") == "/w/a/b.swift")
    #expect(IDE.uri(for: "/abs/../c.swift", cwd: "/w") == "/c.swift")
    #expect(IDE.uri(for: "my file.swift:7", cwd: "/w") == "file:///w/my%20file.swift#L7")
    #expect(IDE.uri(for: "session:abc-def", cwd: "/w") == "session:abc-def")
}
