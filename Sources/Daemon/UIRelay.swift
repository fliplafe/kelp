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

extension StateGet: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        if let prefix { return .object(try d.store.uiState(prefix: prefix)) }
        guard let key else { throw RPCError.invalidParams("missing key") }
        return try d.store.uiState(prefix: key)[key] ?? .null
    }
}

extension StateSet: Handled {
    func handle(_ d: Daemon) throws -> Done { try d.store.setUIState(key, value); return Done() }
}
