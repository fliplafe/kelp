import Foundation

/// OSC 7501, "Program Status": agents (Claude Code, Codex, Grok, pi…) report their own state through the terminal
/// once the terminal answers their probe. No hooks, nothing written to the agent's config.
/// Spec: https://www.superlogical.com/rex/docs/build/program-status
public enum ProgramStatus {
    public static let prefix = "\u{1B}]7501;"
    /// The only bytes a terminal that understands the protocol writes back to the `?` probe.
    public static let queryReply = "\u{1B}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1B}\\"
    static let states: Set<String> = ["idle", "working", "done", "blocked", "error", "clear"]

    public struct Report: Equatable, Sendable {
        /// nil: the program itself; otherwise one of its children (a subagent).
        public var id: String?
        public var state: String
        public var kind: String?
        public var msg: String?
    }
    public enum Message: Equatable, Sendable { case query, report(Report) }

    /// Messages in a chunk of output. `carry` keeps a sequence cut off at the end of one read for the next.
    public static func scan(_ chunk: String, carry: inout String) -> [Message] {
        var s = carry + chunk
        carry = ""
        var out: [Message] = []
        while let r = s.range(of: prefix) {
            let body = s[r.upperBound...]
            guard let end = body.firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1B}" }) else {
                if body.utf8.count < 4096 { carry = String(s[r.lowerBound...]) }   // unfinished: wait for the rest
                return out
            }
            if let m = parse(String(body[..<end])) { out.append(m) }
            s = String(body[body.index(after: end)...])
        }
        // "…\u{1B}]75" at the very end: the start of a sequence the next read completes.
        if let i = s.lastIndex(of: "\u{1B}"), prefix.hasPrefix(String(s[i...])) { carry = String(s[i...]) }
        return out
    }

    /// The text between `OSC 7501;` and the terminator. nil: not a report (ignored).
    public static func parse(_ body: String) -> Message? {
        guard body.utf8.count <= 4096 else { return nil }
        if body.trimmingCharacters(in: .whitespaces) == "?" { return .query }
        var pairs: [String: String] = [:]
        for pair in body.split(separator: ":") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let k = pair[..<eq].trimmingCharacters(in: .whitespaces), v = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard k.count <= 16, k.allSatisfy({ $0.isLowercase && $0.isASCII }) else { continue }
            pairs[k] = v
        }
        guard let state = pairs["state"], states.contains(state) else { return nil }
        let msg = pairs["msg"].flatMap { $0.count <= 2732 ? Data(base64Encoded: padded($0)) : nil }
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) } ? nil : $0 }
        return .report(Report(id: pairs["id"], state: state, kind: state == "blocked" ? pairs["kind"] : nil, msg: msg))
    }

    private static func padded(_ s: String) -> String {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return t + String(repeating: "=", count: (4 - t.count % 4) % 4)
    }
}
