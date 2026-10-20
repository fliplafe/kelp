import Foundation

/// OSC 7501, "Program Status": agents (Claude Code, Codex, Grok, pi…) report their own state through the terminal
/// once the terminal answers their probe. No hooks, nothing written to the agent's config.
/// Spec: https://www.superlogical.com/rex/docs/build/program-status
public enum ProgramStatus {
    public static let prefix = "\u{1B}]7501;"
    /// The only bytes a terminal that understands the protocol writes back to the `?` probe.
    public static let queryReply = "\u{1B}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1B}\\"
    public static let states: Set<String> = ["idle", "working", "done", "blocked", "error", "clear"]

    public struct Report: Equatable, Sendable {
        /// nil: the program itself; otherwise one of its children (a subagent).
        public var id: String?
        public var state: String
        public var kind: String?
        public var msg: String?
        /// 0–100, while it works.
        public var progress: Int?
        public init(id: String? = nil, state: String, kind: String? = nil, msg: String? = nil, progress: Int? = nil) {
            self.id = id; self.state = state; self.kind = kind; self.msg = msg; self.progress = progress
        }
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
        let progress = state == "working" ? pairs["progress"].flatMap { Int($0) }.map { min(100, max(0, $0)) } : nil
        return .report(Report(id: pairs["id"], state: state, kind: state == "blocked" ? pairs["kind"] : nil, msg: msg, progress: progress))
    }

    public static let conEmuPrefix = "\u{1B}]9;4;"
    /// ConEmu's progress bar, `OSC 9;4;<state>;<percent>`, which build tools such as cargo write: each one's percent in
    /// order, nil where the bar went away or has none (state 0 removes it, 3 is indeterminate, 2 an error).
    public static func conEmuProgress(_ chunk: String) -> [Int?] {
        chunk.components(separatedBy: conEmuPrefix).dropFirst().compactMap { body -> Int?? in
            // Cut off between two reads: skipped, the tool writes the next one soon.
            guard let end = body.firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1B}" }) else { return nil }
            let f = body[..<end].split(separator: ";", omittingEmptySubsequences: false)
            guard f.first == "1" || f.first == "4", f.count > 1, let n = Int(f[1]) else { return .some(nil) }
            return min(100, max(0, n))
        }
    }

    private static func padded(_ s: String) -> String {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return t + String(repeating: "=", count: (4 - t.count % 4) % 4)
    }
}
