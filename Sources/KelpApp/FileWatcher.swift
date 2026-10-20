import Foundation
import CoreServices

/// FSEvents on a directory tree, debounced; reports changed absolute paths on the main thread. Build output under the
/// root (node_modules, .build…: ignored, never in the tree) is dropped on the stream's own queue first: a build or an
/// `npm install` writes thousands of files a second, and every watcher of the folder sorted through them on main.
/// Limit: a fixed list of usual build folders; a tracked folder named like one updates on the next other change.
final class FileWatcher {
    static let buildFolders: Set<Substring> = ["node_modules", ".build", "DerivedData", ".next", "__pycache__", ".gradle", ".swiftpm", ".venv", "target"]
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.kelp.filewatcher")
    private let roots: [String]
    private let handler: ([String]) -> Void

    init?(root: String, latency: Double = 0.25, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        roots = Array(Set([root, Self.real(root)].map { $0.hasSuffix("/") ? $0 : $0 + "/" }))
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let kept = arr.prefix(n).filter { !FileWatcher.isBuildOutput($0, under: me.roots) }
            guard !kept.isEmpty else { return }
            let handler = me.handler
            DispatchQueue.main.async { handler(kept) }
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    /// The path FSEvents reports for `path`: /private/tmp for /tmp (URL.resolvingSymlinksInPath strips /private again).
    static func real(_ path: String) -> String {
        realpath(path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? path
    }

    static func isBuildOutput(_ path: String, under roots: [String]) -> Bool {
        guard let root = roots.first(where: path.hasPrefix) else { return false }
        return path.dropFirst(root.count).split(separator: "/").contains(where: buildFolders.contains)
    }

    deinit {
        // On the stream's queue: no callback is running (or can start) once this returns, so `self` isn't read after it's gone.
        if let s = stream { queue.sync { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) } }
    }
}
