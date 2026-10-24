import Foundation
import os
import Core

/// The daemon's log, for what would otherwise fail without a trace: `log stream --predicate 'subsystem == "dev.kelp.daemon"'`
/// (or Console.app). Never terminal output, prompts, tokens or file contents; paths and messages stay private in the
/// system log unless marked public.
enum Log {
    static let start = Logger(subsystem: "dev.kelp.daemon", category: "start")
    static let store = Logger(subsystem: "dev.kelp.daemon", category: "store")
    static let rpc = Logger(subsystem: "dev.kelp.daemon", category: "rpc")
    static let session = Logger(subsystem: "dev.kelp.daemon", category: "session")
}

extension Logger {
    /// `body`'s value, or nil with the error in this log: for what may fail without stopping the caller (a cleanup, a
    /// best-effort write), but must not fail unseen as a bare `try?` would.
    @discardableResult
    func attempt<T>(_ what: @autoclosure () -> String, _ body: () throws -> T) -> T? {
        do { return try body() } catch {
            let what = what()
            self.error("\(what, privacy: .public): \(error)")
            return nil
        }
    }
}

extension Clients {
    /// KelpApp beside this daemon (one bundle, or one build folder); KELP_APP_EXECUTABLE stands in for it in tests.
    static var appExecutable: String {
        #if DEBUG   // tests stand in for the app; a release build takes no word for it from whoever started kelpd
        if let e = ProcessInfo.processInfo.environment["KELP_APP_EXECUTABLE"] { return URL(fileURLWithPath: e).resolvingSymlinksInPath().path }
        #endif
        let me = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return me.deletingLastPathComponent().appendingPathComponent("KelpApp").resolvingSymlinksInPath().path
    }

    /// For what only Kelp's window may do (its state, trusting a project): anyone else is refused, and the log says who,
    /// so a second install or a stale app (whose path isn't the one beside this daemon) can be told apart.
    func requireApp(_ conn: Int, _ refusal: String) throws {
        let peer = peer(conn)
        guard peer != Self.appExecutable else { return }
        Log.rpc.notice("refused \(refusal, privacy: .public): \(peer ?? "an unknown program", privacy: .public) isn't \(Self.appExecutable, privacy: .public)")
        throw RPCError.invalidParams(refusal)
    }
}
