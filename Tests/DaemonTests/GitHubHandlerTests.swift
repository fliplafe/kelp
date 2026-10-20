import Foundation
import Testing
import Core
import GitKit
@testable import Daemon

/// A stand-in for `gh`: logs its arguments, answers with canned JSON. Set up once, before anything asks for gh.
private let fakeGh: (log: String, script: String) = {
    let dir = tmp(), log = dir.appendingPathComponent("gh.log").path, script = dir.appendingPathComponent("gh").path
    let body = """
    #!/bin/sh
    echo "$@" >> '\(log)'
    case "$1 $2" in
      "pr list") echo '[{"author":{"login":"ada"},"headRefName":"feat/x","isDraft":false,"number":7,"reviewDecision":"APPROVED","state":"OPEN","title":"Add login","url":"https://github.com/o/r/pull/7","statusCheckRollup":[]}]';;
      "issue list") echo '[{"assignees":[{"login":"ada"}],"body":"Steps","labels":[{"name":"bug"}],"number":3,"state":"OPEN","title":"Crash","url":"https://github.com/o/r/issues/3"}]';;
      "pr checks") if [ "$3" = "404" ]; then echo "no checks reported on the 'x' branch" >&2; exit 1; fi
                   echo '[{"bucket":"fail","link":"https://github.com/o/r/actions/runs/99/job/1","name":"test","state":"FAILURE","workflow":"CI"}]';;
      "run view") case "$*" in
                    *"--json jobs"*) echo '{"jobs":[{"databaseId":5,"name":"build","status":"completed","conclusion":"failure","url":"https://github.com/o/r/actions/runs/99/job/5","steps":[{"name":"Compile","status":"completed","conclusion":"failure"}]}]}';;
                    *"--job"*"--log-failed"*) printf 'build\\tCompile\\t2026-10-20T10:00:00Z error: boom\\n';;
                    *) printf 'step 1\\nstep 2 failed\\n';;
                  esac;;
      "run list") echo '[{"databaseId":99,"displayTitle":"Add login","workflowName":"CI","status":"completed","conclusion":"failure","event":"push","url":"https://github.com/o/r/actions/runs/99","createdAt":"2026-10-20T10:00:00Z"}]';;
      "run rerun"|"workflow run") ;;
      "pr view") echo '{"reviews":[{"id":"R1","author":{"login":"bob"},"body":"Please rename","state":"CHANGES_REQUESTED"}]}';;
      "api --paginate") echo '[[{"path":"a.swift","line":3,"original_line":3,"body":"nit","user":{"login":"amy"},"html_url":"https://github.com/o/r/pull/7#r1"}]]';;
      "api user") echo ada;;
      *) echo "unexpected: $*" >&2; exit 1;;
    esac
    """
    try? body.write(toFile: script, atomically: true, encoding: .utf8)
    chmod(script, 0o755)
    setenv("KELP_GH", script, 1)
    return (log, script)
}()
private func calls() -> [String] { ((try? String(contentsOfFile: fakeGh.log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

private func rig() async throws -> (d: Daemon, c: RPCClient, repo: Repo) {
    _ = fakeGh
    let root = tmp(); let d = try Daemon(root: root); try d.start()
    let c = try RPCClient(socket: root.appendingPathComponent("kelp.sock").path)
    return (d, c, try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self))
}

@Test func theDaemonListsPullRequestsFromGh() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let prs = try await r.c.call("github.prs", .obj(["repoId": .string(r.repo.id)])).array ?? []
    #expect(prs.count == 1 && prs[0]["number"]?.int == 7 && prs[0]["author"]?.string == "ada" && prs[0]["reviewDecision"]?.string == "APPROVED")
    #expect(calls().contains { $0.hasPrefix("pr list") && $0.contains("--json") })
}

@Test func issuesAskForMineOnlyWhenToldTo() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let all = try await r.c.call("github.issues", .obj(["repoId": .string(r.repo.id)])).array ?? []
    #expect(all.first?["labels"]?.array?.first?.string == "bug")
    let before = calls().filter { $0.hasPrefix("issue list") }
    #expect(before.last?.contains("--assignee") == false)
    _ = try await r.c.call("github.issues", .obj(["repoId": .string(r.repo.id), "filter": "mine"]))
    #expect(calls().filter { $0.hasPrefix("issue list") }.last?.contains("--assignee @me") == true)
}

@Test func checksComeBackAndNoChecksIsAnEmptyListNotAnError() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let checks = try await r.c.call("github.checks", .obj(["repoId": .string(r.repo.id), "pr": 7])).array ?? []
    #expect(checks.first?["runId"]?.int == 99 && checks.first?["bucket"]?.string == "fail")
    #expect(try await r.c.call("github.checks", .obj(["repoId": .string(r.repo.id), "pr": 404])).array?.isEmpty == true)
}

@Test func aFailedRunsLogIsTextFromGh() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let log = try await r.c.call("github.failedLog", .obj(["repoId": .string(r.repo.id), "runId": 99])).string ?? ""
    #expect(log.contains("step 2 failed"))
    #expect(calls().contains("run view 99 --log-failed"))
}

@Test func githubStatusSaysWhoIsSignedIn() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let s = try await r.c.call("github.status")
    #expect(s["installed"]?.bool == true && s["user"]?.string == "ada")
}

@Test func theBranchsPullRequestIsCachedForTwoMinutes() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let wt: Worktree = try await r.c.call("worktree.create", .obj(["repoId": .string(r.repo.id), "branch": "feat/x", "setup": false]), as: Worktree.self)
    let n0 = calls().filter { $0.contains("--head feat/x") }.count
    let first = try await r.c.call("github.branchPR", .obj(["worktreeId": .string(wt.id)]))
    #expect(first["number"]?.int == 7)
    _ = try await r.c.call("github.branchPR", .obj(["worktreeId": .string(wt.id)]))
    #expect(calls().filter { $0.contains("--head feat/x") }.count == n0 + 1)   // the second answer didn't ask gh again
}

@Test func theForgeIsGithubForAPlainRepo() async throws {
    let r = try await rig(); defer { r.d.stop() }
    #expect(try await r.c.call("github.forge", .obj(["repoId": .string(r.repo.id)])).string == "github")
}

private func wtOf(_ r: (d: Daemon, c: RPCClient, repo: Repo), branch: String = "feat/x") async throws -> Worktree {
    try await r.c.call("worktree.create", .obj(["repoId": .string(r.repo.id), "branch": .string(branch), "setup": false]), as: Worktree.self)
}

@Test func ciRunsJobsLogsAndRerunsGoThroughGh() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let wt = try await wtOf(r)
    let runs = try await r.c.call("ci.runs", .obj(["worktreeId": .string(wt.id)]))
    #expect(runs["branch"]?.string == "feat/x" && runs["runs"]?.array?.first?["id"]?.int == 99 && runs["runs"]?.array?.first?["conclusion"]?.string == "failure")
    let jobs = try await r.c.call("ci.jobs", .obj(["worktreeId": .string(wt.id), "run": 99])).array ?? []
    #expect(jobs.first?["name"]?.string == "build" && jobs.first?["steps"]?.array?.first?["name"]?.string == "Compile")
    let log = try await r.c.call("ci.log", .obj(["worktreeId": .string(wt.id), "job": 5])).string ?? ""
    #expect(log.contains("error: boom") && !log.contains("2026-10-20T10:00:00Z"))   // the timestamp column is stripped
    _ = try await r.c.call("ci.rerun", .obj(["worktreeId": .string(wt.id), "run": 99]))
    #expect(calls().contains("run rerun 99 --failed"))
    _ = try await r.c.call("ci.dispatch", .obj(["worktreeId": .string(wt.id), "workflow": "ci.yml", "branch": "feat/x", "inputs": .object(["b": "2", "a": "1"])]))
    #expect(calls().contains("workflow run ci.yml --ref feat/x -f a=1 -f b=2"))   // inputs in a stable order
}

@Test func reviewCommentsMergeReviewsAndInlineComments() async throws {
    let r = try await rig(); defer { r.d.stop() }
    let c = try await r.c.call("github.reviewComments", .obj(["repoId": .string(r.repo.id), "pr": 7])).array ?? []
    #expect(c.compactMap { $0["author"]?.string }.sorted() == ["amy", "bob"])
    #expect(c.first { $0["author"]?.string == "amy" }?["path"]?.string == "a.swift")
}
