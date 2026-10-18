import Foundation
import Daemon

// krilld: background daemon. Run by launchd (see `krill install`) or directly.
signal(SIGPIPE, SIG_IGN)
do {
    let d = try Daemon()
    try d.start()
    for s in [SIGTERM, SIGINT] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
        src.setEventHandler { d.stop(); exit(0) }
        src.resume()
    }
    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("krilld: \(error)\n".utf8))
    exit(1)
}
