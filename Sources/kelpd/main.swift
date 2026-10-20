import Foundation
import Daemon

// kelpd: background daemon. Run by launchd (see `kelp install`) or started on demand by the app/CLI.
signal(SIGPIPE, SIG_IGN)
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []   // must outlive this scope or the handlers vanish
do {
    let d = try Daemon()
    try d.start()
    for s in [SIGTERM, SIGINT, SIGHUP] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
        src.setEventHandler { @Sendable in d.stop(); exit(0) }
        src.resume()
        signalSources.append(src)
    }
    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("kelpd: \(error)\n".utf8))
    exit(1)
}
