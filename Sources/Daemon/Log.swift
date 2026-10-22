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

extension Daemon {
    /// kelpd couldn't start: the reason goes to the log and to `Paths.daemonError(in:)`, where the app reads it for its
    /// "background service isn't running" banner (the app starts kelpd with its output thrown away). The file goes once a
    /// daemon starts. Limit: a KELP_HOME that can't be written can't hold it either; then only the log and stderr have it.
    public static func startFailed(_ error: Error, root: URL) -> String {
        let why = (error as? RPCError)?.message ?? "\(error)"
        Log.start.fault("kelpd didn't start: \(why, privacy: .public)")
        try? Data((why + "\n").utf8).write(to: Paths.daemonError(in: root))
        return why
    }

    func requireApp(_ conn: Int, _ refusal: String) throws { try clients.requireApp(conn, refusal) }
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
