import Foundation
import Daemon

// kelpd: background daemon. Run by launchd (see `kelp install`) or started on demand by the app/CLI.
signal(SIGPIPE, SIG_IGN)
// launchd gives 256 fds; every agent holds 3, every open terminal 2 more, every git or gh run 2: take what's allowed.
var files = rlimit()
if getrlimit(RLIMIT_NOFILE, &files) == 0, files.rlim_cur < rlim_t(OPEN_MAX) {
    files.rlim_cur = min(files.rlim_max, rlim_t(OPEN_MAX)); setrlimit(RLIMIT_NOFILE, &files)
}
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
