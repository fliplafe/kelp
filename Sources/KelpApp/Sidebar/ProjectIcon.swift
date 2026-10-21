import AppKit
import Core

/// A project's own icon, found where web, desktop and Xcode projects keep theirs, at the top or in one of its folders
/// (a monorepo's `frontend/public/`, an app's `Resources/`); a folder when it has none.
@MainActor
enum ProjectIcon {
    private static var cache: [String: NSImage] = [:]
    /// Where icons are kept, relative to the project or one of its top folders.
    static let places = ["", "public/", "static/", "app/", "src/app/", "src/assets/", "assets/", "Assets/", "Resources/",
                         "img/", "images/", "icons/", "build/", "src-tauri/icons/", "docs/", ".github/"]
    /// What they're called, best first; any other `.icns`, then an Xcode AppIcon set, come after these.
    static let names = ["AppIcon.icns", "icon.icns", "apple-touch-icon.png", "favicon.svg", "icon.svg", "icon.png",
                        "favicon.png", "favicon.ico", "logo.svg", "logo.png"]

    static func image(for repo: String) -> NSImage {
        if let i = cache[repo] { return i }
        if RemoteHost.of(repo) != nil { let i = NSImage.symbol("network"); cache[repo] = i; return i }   // on another machine
        // The cell's image view scales it to fit; a wordmark (much wider than tall) would be a line, so it's the initial.
        // A Mac app's icon loses its margin and fills a tile, like the agents' icons.
        let file = find(in: repo)
        let img = file.flatMap(NSImage.init(contentsOfFile:)).flatMap { $0.size.width <= $0.size.height * 2 ? $0 : nil }
            .map { file?.hasSuffix(".icns") == true ? IconTile.app($0) : $0 }
            ?? IconTile.letter((repo as NSString).lastPathComponent)
        cache[repo] = img
        return img
    }

    /// The project's own places first, then each top folder's. A bounded look, it runs while the sidebar draws.
    static func find(in repo: String) -> String? {
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
    private static func appIconSet(_ dir: String) -> String? {
        let pngs = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".png") }
        return pngs.max { fileSize(dir + "/" + $0) < fileSize(dir + "/" + $1) }.map { dir + "/" + $0 }
    }
    private static func fileSize(_ p: String) -> Int { (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0 }
}
