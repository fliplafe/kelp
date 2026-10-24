import AppKit
import Core

/// A project's own icon, found where web, desktop and Xcode projects keep theirs, at the top or in one of its folders
/// (a monorepo's `frontend/public/`, an app's `Resources/`); its initial when it has none.
@MainActor
enum ProjectIcon {
    private static var cache: [String: NSImage] = [:]
    /// Projects being looked at, and the views showing their initial meanwhile.
    private static var looking: [String: [Weak]] = [:]
    private struct Weak { weak var view: NSImageView? }
    /// Where icons are kept, relative to the project or one of its top folders.
    nonisolated static let places = ["", "public/", "static/", "app/", "src/app/", "src/assets/", "assets/", "Assets/", "Resources/",
                                     "img/", "images/", "icons/", "build/", "src-tauri/icons/", "docs/", ".github/"]
    /// What they're called, best first; any other `.icns`, then an Xcode AppIcon set, come after these.
    nonisolated static let names = ["AppIcon.icns", "icon.icns", "apple-touch-icon.png", "favicon.svg", "icon.svg", "icon.png",
                                    "favicon.png", "favicon.ico", "logo.svg", "logo.png"]

    /// `view` shows the project's icon: its initial at once, the icon when found.
    static func show(_ repo: String, in view: NSImageView) {
        view.image = image(for: repo)
        looking[repo]?.append(Weak(view: view))
    }

    /// The project's icon, or its initial while the icon is looked for off the main thread (dozens of folders listed, on
    /// whatever disk the project is on, held up the sidebar); `show` puts the icon in once it's found.
    static func image(for repo: String) -> NSImage {
        if let i = cache[repo] { return i }
        if RemoteHost.of(repo) != nil { // on another machine
            let i = NSImage.symbol("network")
            cache[repo] = i
            return i
        }
        let letter = IconTile.letter((repo as NSString).lastPathComponent)
        cache[repo] = letter; looking[repo] = []
        Task {
            let found = await Task.detached { find(in: repo).flatMap { p in FileManager.default.contents(atPath: p).map { (p, $0) } } }.value
            let views = looking.removeValue(forKey: repo) ?? []
            // The cell's image view scales it to fit; a wordmark (much wider than tall) would be a line, so it's the initial.
            // A Mac app's icon loses its margin and fills a tile, like the agents' icons.
            guard let (file, data) = found, let img = NSImage(data: data), img.size.width <= img.size.height * 2 else { return }
            let icon = file.hasSuffix(".icns") ? IconTile.app(img) : img
            cache[repo] = icon
            for v in views where v.view?.image === letter { v.view?.image = icon }
        }
        return letter
    }

    /// The project's own places first, then each top folder's. A bounded look.
    nonisolated static func find(in repo: String) -> String? {
        let fm = FileManager.default
        let tops = ((try? fm.contentsOfDirectory(atPath: repo)) ?? []).filter { !$0.hasPrefix(".") && $0 != "node_modules" }.sorted().prefix(40)
        for base in [""] + tops.map({ $0 + "/" }) {
            let dirs = places.compactMap { p -> (String, [String])? in
                let dir = repo + "/" + base + p
                return (try? fm.contentsOfDirectory(atPath: dir)).map { (dir, $0) }
            }
            for n in names { if let (dir, _) = dirs.first(where: { $0.1.contains(n) }) { return dir + n } }
            for (dir, files) in dirs { if let icns = files.sorted().first(where: { $0.hasSuffix(".icns") }) { return dir + icns } }
            for (dir, files) in dirs where files.contains("Assets.xcassets") {
                if let p = appIconSet(dir + "Assets.xcassets/AppIcon.appiconset") { return p }
            }
        }
        return nil
    }

    /// The largest PNG of an Xcode AppIcon set.
    private nonisolated static func appIconSet(_ dir: String) -> String? {
        let pngs = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".png") }
        return pngs.max { fileSize(dir + "/" + $0) < fileSize(dir + "/" + $1) }.map { dir + "/" + $0 }
    }
    private nonisolated static func fileSize(_ p: String) -> Int { (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0 }
}
