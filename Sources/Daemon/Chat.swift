import Foundation
import Core
import Agents

/// A structured chat with Claude Code (stream-json in/out), owned by the daemon so it survives the UI like a terminal does.
final class ChatSession: @unchecked Sendable {
    let id = UUID().uuidString
    let worktreeId: String
    private let proc = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var lines: [String] = []
    var onLine: (@Sendable (String, String) -> Void)?   // (chat id, JSON line)
    var running: Bool { proc.isRunning }

    init(worktreeId: String, cwd: String, model: String?, yolo: Bool, env: [String: String]) throws {
        self.worktreeId = worktreeId
        var args = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-mode", yolo ? "bypassPermissions" : "acceptEdits"]
        if let model, !model.isEmpty { args += ["--model", model] }
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env"); proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = ProcessInfo.processInfo.environment.filter { k, _ in !PTY.scrubbed.contains { k.hasPrefix($0) } }.merging(env) { $1 }
        proc.standardInput = input; proc.standardOutput = output; proc.standardError = FileHandle.nullDevice
        try proc.run()
        Thread.detachNewThread { [self] in
            var lb = LineBuffer()
            while true {
                let d = output.fileHandleForReading.availableData
                if d.isEmpty { break }
                for l in lb.append(d) {
                    let s = String(decoding: l, as: UTF8.self)
                    lock.withLock { lines.append(s) }
                    onLine?(id, s)
                }
            }
            onLine?(id, #"{"type":"krill_exit"}"#)
        }
    }

    func send(_ text: String) {
        lock.withLock { lines.append(String(decoding: ChatEvent.userLine(text), as: UTF8.self).trimmingCharacters(in: .newlines)) }
        try? input.fileHandleForWriting.write(contentsOf: ChatEvent.userLine(text))
    }
    func stop() { if proc.isRunning { proc.interrupt(); proc.terminate() } }
    var transcript: [String] { lock.withLock { lines } }
}

extension Daemon {
    func handleChat(_ method: String, _ p: JSONValue) throws -> JSONValue? {
        switch method {
        case "chat.start":
            let w = try cwd(forWorktree: p.req("worktreeId"))
            let c = try ChatSession(worktreeId: w.id, cwd: w.path, model: p["model"]?.string, yolo: p["mode"]?.string == "yolo",
                                    env: ["KRILL_SOCKET": socketPath, "KRILL_HOME": root.path])
            c.onLine = { [weak self] id, line in self?.notify("event.chat", .obj(["id": .string(id), "line": .string(line)])) }
            lock.withLock { chats[c.id] = c }
            return .obj(["id": .string(c.id)])
        case "chat.send":
            guard let c = lock.withLock({ chats[(p["id"]?.string ?? "")] }) else { throw RPCError.invalidParams("no chat") }
            c.send(try p.req("text")); return .null
        case "chat.stop":
            lock.withLock { chats[(p["id"]?.string ?? "")] }?.stop(); return .null
        case "chat.history":
            guard let c = lock.withLock({ chats[(p["id"]?.string ?? "")] }) else { return .array([]) }
            return .array(c.transcript.map { .string($0) })
        case "chat.list":
            return .array(lock.withLock { Array(chats.values) }.map { .obj(["id": .string($0.id), "worktreeId": .string($0.worktreeId), "running": .bool($0.running)]) })
        default: return nil
        }
    }
}
