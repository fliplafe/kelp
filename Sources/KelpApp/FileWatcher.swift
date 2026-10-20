import Foundation
import CoreServices

/// FSEvents on a directory tree, debounced; reports changed absolute paths.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(root: String, latency: Double = 0.25, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.handler(Array(arr.prefix(n)))
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }
}
