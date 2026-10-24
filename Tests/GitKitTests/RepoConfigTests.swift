import Foundation
import Testing
@testable import GitKit
@testable import Core
import TestSupport

/// A folder's own git config (one that came as a download) runs no program when Kelp reads its history: no signature
/// is checked, whatever `log.showSignature` and `gpg.program` say.
@Test func readingHistoryRunsNoSignatureProgram() throws {
    let repo = try tempRepo()
    let marker = repo + "/ran", script = repo + "/gpg.sh"
    try "#!/bin/sh\ntouch \(marker)\n".write(toFile: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    let tree = try Git.run(["write-tree"], cwd: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    let signed = "tree \(tree)\nauthor a <a@a> 0 +0000\ncommitter a <a@a> 0 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n x\n -----END PGP SIGNATURE-----\n\nsigned\n"
    try signed.write(toFile: repo + "/commit.txt", atomically: true, encoding: .utf8)
    let sha = try Git.run(["hash-object", "-t", "commit", "-w", "commit.txt"], cwd: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    try Git.run(["update-ref", "HEAD", sha], cwd: repo)
    try Git.run(["config", "log.showSignature", "true"], cwd: repo)
    try Git.run(["config", "gpg.program", script], cwd: repo)
    _ = try Git.run(["log", "--format=%h", "HEAD"], cwd: repo)
    _ = try Git.run(["show", "--stat", "HEAD"], cwd: repo)
    #expect(!FileManager.default.fileExists(atPath: marker))
}
