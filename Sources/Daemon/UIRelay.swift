import Foundation
import Core

/// Agents → app: `kelp open`, `kelp ui` etc. call `ui.*`; the daemon relays them to the app as `event.ui`.
/// The app publishes what it shows (`ui.publish`) so agents can read it back (`ui.state`), and keeps what it restores
/// (each workspace's layout, the sidebar's order…) in the database with `state.*`, so every KELP_HOME has its own.
extension UIPublish: Handled {
    func handle(_ d: Daemon) throws -> Done { try handle(d, conn: -1) }
    func handle(_ d: Daemon, conn: Int) throws -> Done {
        guard case .object = state else { throw RPCError.invalidParams("state must be an object") }
        // Only Kelp's window says what's on screen (and gets event.ui): an agent can't stand in for it.
        guard d.clients.peer(conn) == Daemon.appExecutable else { throw RPCError.invalidParams("Only Kelp's window publishes its state.") }
        d.clients.publishUI(state, from: conn)
        return Done()
    }
}

extension UIStateGet: Handled { func handle(_ d: Daemon) throws -> JSONValue { d.clients.uiState } }

extension UIOpen: Handled {
    func handle(_ d: Daemon) throws -> Delivered {
        if let split, split != "right", split != "down" { throw RPCError.invalidParams("split must be \"right\" or \"down\"") }
        return try d.relay("open", self)
    }
}

extension UICommand: Handled { func handle(_ d: Daemon) throws -> Delivered { try d.relay("command", self) } }

extension Daemon {
    static let uiMethods: [any Handled.Type] = [UIPublish.self, UIStateGet.self, UIOpen.self, UICommand.self]

    /// To every Kelp window as `event.ui`: the request's fields and `action`.
    fileprivate func relay(_ action: String, _ request: some RPCMethod) throws -> Delivered {
        let apps = clients.apps
        guard !apps.isEmpty else { throw RPCError.internalError("The Kelp app isn't running") }
        var params: [String: JSONValue] = if case .object(let o)? = try request.params() { o } else { [:] }
        params["action"] = .string(action)
        notify("event.ui", .object(params), to: apps)
        return Delivered(delivered: apps.count)
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
    func handle(_ d: Daemon) throws -> Done { try handle(d, conn: -1) }
    func handle(_ d: Daemon, conn: Int) throws -> Done {
        // Which projects may run their own code in language servers and formatters: the user's say, in Kelp's window
        // (as `scripts.trust`); an agent's call or a repository's script can't record it.
        if key.hasPrefix("lsp."), d.clients.peer(conn) != Daemon.appExecutable {
            throw RPCError.invalidParams("Only Kelp's window can trust a project for language servers.")
        }
        try d.store.setUIState(key, value); return Done()
    }
}
