import Foundation
import Core

/// Agents → app: `kelp open`, the MCP tools etc. call `ui.*`; the daemon relays them to the app as `event.ui`.
/// The app publishes what it shows (`ui.publish`) so agents can read it back (`ui.state`), and keeps what it restores
/// (each workspace's layout, the sidebar's order…) in the database with `state.*`, so every KELP_HOME has its own.
extension Daemon {
    func handleUI(_ method: String, _ p: JSONValue, conn: Int) throws -> JSONValue? {
        switch method {
        case "ui.publish":
            guard let state = p["state"], case .object = state else { throw RPCError.invalidParams("state must be an object") }
            lock.withLock { uiState = state; appConns.insert(conn) }
            return .null
        case "ui.state": return lock.withLock { uiState }
        case "state.get":   // {key} → its value or null; {prefix} → {key: value} for every key that starts with it
            if let prefix = p["prefix"]?.string { return .object(try store.uiState(prefix: prefix)) }
            let key = try p.req("key")
            return try store.uiState(prefix: key)[key] ?? .null
        case "state.set":   // {key, value}: a null or missing value deletes the key
            try store.setUIState(p.req("key"), p["value"].flatMap { $0 == .null ? nil : $0 })
            return .null
        case "ui.open":
            _ = try p.req("uri")
            if let s = p["split"], s != "right", s != "down" { throw RPCError.invalidParams("split must be \"right\" or \"down\"") }
            return try relay("open", p)
        case "ui.command":
            _ = try p.req("id")
            return try relay("command", p)
        default: return nil
        }
    }

    private func relay(_ action: String, _ p: JSONValue) throws -> JSONValue {
        let apps = lock.withLock { appConns.subtracting(rawConns) }
        guard !apps.isEmpty else { throw RPCError.internalError("The Kelp app isn't running") }
        var params: [String: JSONValue] = if case .object(let o) = p { o } else { [:] }
        params["action"] = .string(action)
        notify("event.ui", .object(params), to: apps)
        return .obj(["delivered": .int(apps.count)])
    }
}
