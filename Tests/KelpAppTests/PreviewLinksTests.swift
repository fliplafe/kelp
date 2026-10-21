import Foundation
import Testing
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
