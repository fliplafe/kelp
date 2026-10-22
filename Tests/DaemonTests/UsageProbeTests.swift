import Foundation
import Testing
@testable import Daemon

/// Codex's limits come from its app server, asked over a terminal (with its input closed it quits before answering);
/// the questions the terminal echoes back aren't taken for the answer.
@Test func codexLimitsComeFromItsAppServer() throws {
    let fake = tmp().appendingPathComponent("codex")
    try """
    #!/bin/bash
    [ "$1" = app-server ] || exit 1
    while IFS= read -r l; do
      case "$l" in *'"id":2'*) echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":14,"resetsAt":1792715745},"secondary":{"usedPercent":2}}}}';; esac
    done
    """.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let l = try #require(AgentUsage.codexLimits(path: fake.path))
    #expect(l.primaryUsedPercent == 14 && l.primaryResetsAt == Date(timeIntervalSince1970: 1_792_715_745) && l.secondaryUsedPercent == 2)
}
