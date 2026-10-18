import Foundation

/// One event from `claude -p --output-format stream-json`, reduced to what a chat view shows.
public enum ChatEvent: Equatable, Sendable {
    case started(model: String, sessionId: String)
    case text(String)                                   // assistant prose (Markdown)
    case tool(id: String, name: String, summary: String) // a tool call, one line ("Edit Sources/App.swift")
    case toolResult(id: String, ok: Bool, preview: String)
    case todos([Todo])                                  // TodoWrite: the agent's plan
    case finished(ok: Bool, costUSD: Double?, turns: Int?)
    case other

    public struct Todo: Equatable, Sendable { public var text: String; public var state: String }   // pending | in_progress | completed

    public static func parse(_ line: Data) -> [ChatEvent] {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        switch o["type"] as? String {
        case "system":
            guard o["subtype"] as? String == "init" else { return [.other] }
            return [.started(model: o["model"] as? String ?? "", sessionId: o["session_id"] as? String ?? "")]
        case "assistant":
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { c in
                switch c["type"] as? String {
                case "text": return (c["text"] as? String).map(ChatEvent.text)
                case "tool_use":
                    let name = c["name"] as? String ?? "tool", input = c["input"] as? [String: Any] ?? [:]
                    if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
                        return .todos(todos.map { Todo(text: ($0["content"] as? String) ?? ($0["activeForm"] as? String) ?? "", state: $0["status"] as? String ?? "pending") })
                    }
                    return .tool(id: c["id"] as? String ?? "", name: name, summary: summary(name, input))
                default: return nil
                }
            }
        case "user":
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { c in
                guard c["type"] as? String == "tool_result" else { return nil }
                let text: String = (c["content"] as? String) ?? ((c["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "")
                return .toolResult(id: c["tool_use_id"] as? String ?? "", ok: !(c["is_error"] as? Bool ?? false), preview: String(text.prefix(400)))
            }
        case "result":
            return [.finished(ok: o["subtype"] as? String == "success" && !(o["is_error"] as? Bool ?? false),
                              costUSD: o["total_cost_usd"] as? Double, turns: o["num_turns"] as? Int)]
        default: return [.other]
        }
    }

    /// "Edit Sources/App.swift", "Bash npm test", "Grep TODO"…
    static func summary(_ name: String, _ i: [String: Any]) -> String {
        let key = ["file_path", "path", "command", "pattern", "url", "query", "description", "prompt"].first { i[$0] is String }
        let arg = key.flatMap { i[$0] as? String }.map { $0.count > 100 ? String($0.prefix(99)) + "…" : $0 } ?? ""
        return arg.isEmpty ? name : "\(name) \(arg)"
    }

    /// stream-json input line for a user turn.
    public static func userLine(_ text: String) -> Data {
        let o: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        var d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data(); d.append(0x0A); return d
    }
}
