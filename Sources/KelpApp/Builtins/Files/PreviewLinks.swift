import AppKit
import WebKit
import WorkbenchKit

/// Links clicked in a rendered preview (Markdown, notebooks) open elsewhere instead of replacing the preview: web
/// pages in a browser tab, the repo's files in their own tab, anything else (mailto:…) with its app. Jumps within
/// the page (#heading) stay.
@MainActor
final class PreviewLinks: NSObject, WKNavigationDelegate {
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard a.navigationType == .linkActivated, let u = a.request.url else { decisionHandler(.allow); return }
        if u.fragment != nil, Self.sansFragment(u) == w.url.map(Self.sansFragment) { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        switch u.scheme {
        case "http", "https": Workbench.open(u.absoluteString)
        case "file" where Self.isFile(u): Workbench.open(TabURI.file(u.path))
        default: NSWorkspace.shared.open(u)
        }
    }

    private static func isFile(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && !dir.boolValue
    }

    private static func sansFragment(_ u: URL) -> String { u.absoluteString.components(separatedBy: "#")[0] }
}
