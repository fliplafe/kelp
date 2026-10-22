import AppKit
import WebKit
import WorkbenchKit

/// Links clicked in a rendered preview (Markdown, notebooks) open elsewhere instead of replacing the preview: web
/// pages in a browser tab, the repo's files in their own tab, mail in the mail app. Jumps within the page (#heading)
/// stay. Nothing else opens: the page may come from a cloned repository, and a link to its `tool.app` or to some other
/// app's scheme would run it (files from `git clone` carry no quarantine for Gatekeeper to check).
@MainActor
final class PreviewLinks: NSObject, WKNavigationDelegate {
    enum Target: Equatable { case web(String), file(String), mail(URL), refused }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard a.navigationType == .linkActivated, let u = a.request.url else { decisionHandler(.allow); return }
        if u.fragment != nil, Self.sansFragment(u) == w.url.map(Self.sansFragment) { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        Self.open(u)
    }

    /// A clicked link, by `target`: a web page as a browser tab, a file as a tab, mail in Mail, anything else refused.
    static func open(_ u: URL) {
        switch target(u) {
        case .web(let s): Workbench.open(s)
        case .file(let p): Workbench.open(TabURI.file(p))
        case .mail(let m): NSWorkspace.shared.open(m)
        case .refused: refuse(u)
        }
    }

    /// Says why nothing opened, with the link to copy (a terminal's links go by the same rules: `target`).
    static func refuse(_ u: URL) {
        Banner.show(String(localized: "Links from a preview open web pages and files only, not “\(u.absoluteString)”."),
                    action: (String(localized: "Copy Link"), {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string)
                    }))
    }

    static func target(_ u: URL) -> Target {
        switch u.scheme?.lowercased() {
        case "http", "https": return .web(u.absoluteString)
        case "mailto": return .mail(u)
        case "file" where isPlainFile(u.resolvingSymlinksInPath()): return .file(u.resolvingSymlinksInPath().path)
        default: return .refused
        }
    }

    /// A regular file: not a folder, and so not an app or any other bundle (which the Finder would launch).
    private static func isPlainFile(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func sansFragment(_ u: URL) -> String { u.absoluteString.components(separatedBy: "#")[0] }
}
