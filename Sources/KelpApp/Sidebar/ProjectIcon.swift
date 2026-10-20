import AppKit
import GitKit

/// A project's own icon, found where web, desktop and Xcode projects keep theirs; a folder when it has none.
@MainActor
enum ProjectIcon {
    private static var cache: [String: NSImage] = [:]
    static let candidates = [
        "public/apple-touch-icon.png", "public/favicon.png", "public/favicon.ico", "public/icon.png", "public/logo.png",
        "static/favicon.png", "static/favicon.ico", "app/favicon.ico", "app/icon.png", "src/app/favicon.ico", "src/app/icon.png",
        "favicon.ico", "favicon.png", "icon.png", "logo.png", "assets/icon.png", "assets/logo.png", "resources/icon.png",
        "build/icon.png", "src-tauri/icons/128x128.png", "src-tauri/icons/icon.png", "docs/logo.png", ".github/logo.png"
    ]

    static func image(for repo: String) -> NSImage {
        if let i = cache[repo] { return i }
        if RemoteHost.of(repo) != nil { return NSImage.symbol("network") }   // on another machine
        let fm = FileManager.default
        let found = candidates.lazy.map { repo + "/" + $0 }.first { fm.fileExists(atPath: $0) }.flatMap(NSImage.init(contentsOfFile:))
            ?? xcodeIcon(repo)
        let img = found?.resized(14) ?? NSImage.symbol("folder")
        cache[repo] = img
        return img
    }

    /// The largest PNG of an Xcode project's AppIcon set: `Assets.xcassets` at the top or one folder down
    /// (a bounded look, it runs while the sidebar draws).
    private static func xcodeIcon(_ repo: String) -> NSImage? {
        let fm = FileManager.default
        let tops = ((try? fm.contentsOfDirectory(atPath: repo)) ?? []).filter { !$0.hasPrefix(".") && $0 != "node_modules" }.prefix(40)
        let sets = [""] + tops.flatMap { [$0 + "/", $0 + "/Resources/"] }
        for s in sets {
            let dir = repo + "/" + s + "Assets.xcassets/AppIcon.appiconset"
            let pngs = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".png") }
            if let biggest = pngs.max(by: { fileSize(dir + "/" + $0) < fileSize(dir + "/" + $1) }) { return NSImage(contentsOfFile: dir + "/" + biggest) }
        }
        return nil
    }
    private static func fileSize(_ p: String) -> Int { (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0 }
}
