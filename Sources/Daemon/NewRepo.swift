import Foundation
import Core
import GitKit

/// Add Project's other two ways in: clone by URL (progress as `event.clone`; a half-made folder is removed when it fails
/// or is cancelled) and a new empty project (`git init`, like the scratch project).
extension Daemon {
    /// Running clones by the id the app gave them, for `repo.cloneCancel`.
    final class Clones: Sendable {
        private let running = Locked<[String: Process]>([:])
        func set(_ id: String, _ p: Process?) { running.withLock { $0[id] = p } }
        func cancel(_ id: String) { running.withLock { $0[id] }?.interrupt() }
    }
    static let clones = Clones()

    /// "git@github.com:me/app.git", "https://gitlab.com/me/app" → "app".
    static func repoName(_ url: String) -> String {
        var n = url.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { "/:".contains($0) }).last.map(String.init) ?? ""
        if n.hasSuffix(".git") { n = String(n.dropLast(4)) }
        return n
    }

    /// `parent/name`, checked: a real folder to go in, a plain name, nothing there yet.
    static func newFolder(_ name: String, in parent: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { throw RPCError.invalidParams("Enter a name for the project folder.") }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &dir), dir.boolValue else { throw RPCError.invalidParams("Choose the folder it goes in.") }
        let dest = (parent as NSString).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest) else {
            throw RPCError.invalidParams("“\(name)” already exists in \((parent as NSString).abbreviatingWithTildeInPath).")
        }
        return dest
    }

    /// Makes the folder, or fails if anything is there already: of two clones racing for one name, exactly one gets it.
    static func claim(_ dest: String) -> Bool { mkdir(dest, 0o755) == 0 }

    func clone(_ url: String, into parent: String, id: String, conn: Int) async throws -> String {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !url.hasPrefix("-") else { throw RPCError.invalidParams("Enter the repository's URL.") }
        let dest = try Self.newFolder(Self.repoName(url), in: parent)
        // Made here, atomically: two clones that pick the same name can't both get past this, so the cleanup below only
        // ever removes this clone's own folder (git clones into an empty folder that exists).
        guard Self.claim(dest) else {
            throw RPCError.invalidParams("“\((dest as NSString).lastPathComponent)” already exists in \((parent as NSString).abbreviatingWithTildeInPath).")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["clone", "--progress", "--", url, dest]
        var env = ProcessInfo.processInfo.environment; env["GIT_TERMINAL_PROMPT"] = "0"; env["LC_ALL"] = "C"
        proc.environment = env
        let err = Pipe(); proc.standardError = err; proc.standardOutput = FileHandle.nullDevice; proc.standardInput = FileHandle.nullDevice
        // git rewrites its progress line with \r: pass the latest one on, at most a few times a second.
        let log = CloneLog()
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let line = log.add(h.availableData) else { return }
            self?.notify("event.clone", .obj(["id": .string(id), "line": .string(line)]), to: [conn])
        }
        Self.clones.set(id, proc)
        let status: (Int32, Process.TerminationReason) = try await withCheckedThrowingContinuation { c in
            proc.terminationHandler = { c.resume(returning: ($0.terminationStatus, $0.terminationReason)) }
            do { try proc.run() } catch { proc.terminationHandler = nil; c.resume(throwing: error) }
        }
        Self.clones.set(id, nil)
        err.fileHandleForReading.readabilityHandler = nil
        guard status.0 == 0 else {
            try? FileManager.default.removeItem(atPath: dest)   // this clone made it (mkdir above), nobody else wrote there
            if status.1 == .uncaughtSignal || status.0 == 130 { throw RPCError.invalidParams("Clone cancelled.") }
            throw RPCError.invalidParams(log.failure ?? "git clone failed (exit code \(status.0)).")
        }
        return dest
    }
}

/// git's stderr during a clone: the last progress line, and what it said when it failed.
final class CloneLog: Sendable {
    private let state = Locked<(text: String, sent: Date)>(("", .distantPast))

    /// The newest complete line, when it's time to show one.
    func add(_ d: Data) -> String? {
        state.withLock { st in
            st.text += String(bytes: d, encoding: .utf8) ?? ""   // git writes ASCII here
            if st.text.count > 8000 { st.text = String(st.text.suffix(4000)) }
            guard Date().timeIntervalSince(st.sent) > 0.2 else { return nil }
            let lines = st.text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            guard let last = lines.last.map(String.init), !last.isEmpty else { return nil }
            st.sent = Date(); return last.trimmingCharacters(in: .whitespaces)
        }
    }

    /// "fatal: repository 'x' not found" → "Repository 'x' not found".
    var failure: String? {
        let lines = state.current.text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
        guard let f = lines.last(where: { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") || $0.hasPrefix("ERROR:") }) ?? lines.last else { return nil }
        var m = f.replacingOccurrences(of: #"^(fatal|error|ERROR): ?"#, with: "", options: .regularExpression)
        m = m.prefix(1).uppercased() + m.dropFirst()
        return m
    }
}

extension RepoClone: AsyncHandled {
    func handle(_ d: Daemon) async throws -> JSONValue { try await handle(d, conn: -1) }
    func handle(_ d: Daemon, conn: Int) async throws -> JSONValue {
        let dest = try await d.clone(url, into: parent, id: id ?? UUID().uuidString, conn: conn)
        return try await d.handle("repo.add", .obj(["path": .string(dest)]), conn: conn)
    }
}
extension RepoCloneCancel: AsyncHandled { func handle(_ d: Daemon) async throws -> JSONValue { Daemon.clones.cancel(id); return .null } }
extension RepoCreate: AsyncHandled {
    func handle(_ d: Daemon) async throws -> JSONValue {
        let dest = try Daemon.newFolder(name, in: parent)
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: false)
        _ = try await d.offload { try Git.run(["init", "-q"], cwd: dest) }
        return try await d.handle("repo.add", .obj(["path": .string(dest)]), conn: -1)
    }
}
