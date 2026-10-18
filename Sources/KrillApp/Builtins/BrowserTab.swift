import AppKit
import WebKit
import Core

/// One web page as a tab: address bar, back/forward, and Design Mode (click an element → its HTML, computed
/// styles and a cropped screenshot go into the focused agent's prompt).
@MainActor
final class BrowserTab: NSObject, TabContent, WKNavigationDelegate, WKScriptMessageHandler, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    let view: NSView
    private let web: WKWebView
    private let address = NSTextField()
    private let designButton = NSButton()
    private var designOn = false
    var uri: String { web.url?.absoluteString ?? start }
    private let start: String
    var title: String { web.title.flatMap { $0.isEmpty ? nil : $0 } ?? web.url?.host ?? "New Page" }
    var icon: NSImage? { .symbol("safari") }
    var toolTip: String? { web.url?.absoluteString }

    init(uri: String) {
        start = uri
        let cfg = WKWebViewConfiguration()
        cfg.preferences.isElementFullscreenEnabled = true
        web = WKWebView(frame: .zero, configuration: cfg)
        web.allowsBackForwardNavigationGestures = true; web.isInspectable = true
        func b(_ sym: String, _ tip: String) -> NSButton {
            let x = NSButton(image: .symbol(sym, tip), target: nil, action: nil); x.bezelStyle = .texturedRounded; x.isBordered = false; x.toolTip = tip; return x
        }
        let back = b("chevron.left", "Back"), fwd = b("chevron.right", "Forward"), reload = b("arrow.clockwise", "Reload"), ext = b("safari", "Open in Safari")
        address.placeholderString = "Search or enter address"; address.lineBreakMode = .byTruncatingTail; address.bezelStyle = .roundedBezel
        designButton.setButtonType(.pushOnPushOff); designButton.bezelStyle = .texturedRounded; designButton.isBordered = false
        designButton.image = .symbol("cursorarrow.rays", "Design Mode"); designButton.toolTip = "Design Mode: click an element to send its HTML, CSS and a screenshot to the agent"
        let bar = NSStackView(views: [back, fwd, reload, address, designButton, ext]); bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view = pinned(bar: bar, body: web)
        super.init()
        web.navigationDelegate = self
        web.configuration.userContentController.add(WeakHandler(self), name: "krill")
        address.delegate = self; address.target = self; address.action = #selector(go)
        back.target = web; back.action = #selector(WKWebView.goBack(_:))
        fwd.target = web; fwd.action = #selector(WKWebView.goForward(_:))
        reload.target = web; reload.action = #selector(WKWebView.reload(_:))
        ext.target = self; ext.action = #selector(openExternal)
        designButton.target = self; designButton.action = #selector(toggleDesign)
        load(uri)
    }

    func focus() { if web.url == nil { view.window?.makeFirstResponder(address) } else { view.window?.makeFirstResponder(web) } }

    func load(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s != "https:", s != "about:blank" else { return }
        let text = s.contains("://") ? s : (s.hasPrefix("localhost") || s.first?.isNumber == true ? "http://" + s
            : s.contains(".") && !s.contains(" ") ? "https://" + s : "https://duckduckgo.com/?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s))
        guard let url = URL(string: text) else { NSSound.beep(); return }
        web.load(URLRequest(url: url)); address.stringValue = url.absoluteString
    }

    @objc private func go() { load(address.stringValue); view.window?.makeFirstResponder(web) }
    @objc private func openExternal() { if let u = web.url { NSWorkspace.shared.open(u) } }

    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { address.stringValue = w.url?.absoluteString ?? ""; onChange?() }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        address.stringValue = w.url?.absoluteString ?? ""; onChange?()
        if designOn { w.evaluateJavaScript(Self.designJS) }
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { showError(e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { showError(e) }
    private func showError(_ e: Error) {
        let msg = (e as NSError).localizedDescription.replacingOccurrences(of: "<", with: "&lt;")
        web.loadHTMLString("<html><body style='font:14px -apple-system;color:#888;display:flex;height:90vh;align-items:center;justify-content:center;text-align:center'><div><b>Can't open this page</b><br>\(msg)<br><br>Is the dev server running?</div></body></html>", baseURL: nil)
    }

    // MARK: Design Mode
    @objc func toggleDesign() {
        designOn.toggle(); designButton.state = designOn ? .on : .off
        designButton.contentTintColor = designOn ? .controlAccentColor : nil
        web.evaluateJavaScript(designOn ? Self.designJS : "window.__krillOff && window.__krillOff()")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any] else { return }
        let r = d["rect"] as? [String: Double] ?? [:]
        let rect = CGRect(x: r["x"] ?? 0, y: r["y"] ?? 0, width: max(1, r["w"] ?? 1), height: max(1, r["h"] ?? 1)).insetBy(dx: -8, dy: -8)
        let cfg = WKSnapshotConfiguration(); cfg.rect = rect.intersection(web.bounds)
        web.takeSnapshot(with: cfg) { [weak self] img, _ in MainActor.assumeIsolated { self?.sendDesign(d, image: img) } }
    }

    private func sendDesign(_ d: [String: Any], image: NSImage?) {
        var shot = ""
        if let img = image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("krill-design-\(UUID().uuidString.prefix(6)).png")
            try? png.write(to: u); shot = u.path
        }
        let styles = (d["styles"] as? [String: String] ?? [:]).filter { !$0.value.isEmpty && $0.value != "none" && $0.value != "normal" }
            .sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value);" }.joined(separator: "\n")
        let msg = """
        Design change for the element `\(d["selector"] as? String ?? "")` on \(d["url"] as? String ?? ""):
        ```html
        \(d["html"] as? String ?? "")
        ```
        Computed styles:
        ```css
        \(styles)
        ```
        \(shot.isEmpty ? "" : "Screenshot: \(shot)\n")
        Change:\u{20}
        """
        guard let sid = Workbench.shared.focusedSession else {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(msg, forType: .string)
            Banner.show("No agent in this workspace — the element details were copied to the clipboard."); return
        }
        Task { await AppModel.shared.call("session.send", .obj(["id": .string(sid), "text": .string(msg), "enter": false])) }
        Workbench.focus(session: sid)
    }

    static let designJS = """
    (() => { if (window.__krill) return; window.__krill = true;
     const box = document.createElement('div');
     box.style.cssText = 'position:fixed;pointer-events:none;border:2px solid #0a84ff;background:rgba(10,132,255,.12);z-index:2147483647;border-radius:3px;display:none';
     const tag = document.createElement('div');
     tag.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;background:#0a84ff;color:#fff;font:11px -apple-system;padding:2px 6px;border-radius:4px;display:none';
     document.documentElement.append(box, tag);
     const move = e => { const r = e.target.getBoundingClientRect();
       Object.assign(box.style, {left: r.left+'px', top: r.top+'px', width: r.width+'px', height: r.height+'px', display: 'block'});
       tag.textContent = e.target.tagName.toLowerCase() + (e.target.classList.length ? '.' + [...e.target.classList].slice(0,2).join('.') : '') + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
       Object.assign(tag.style, {left: r.left+'px', top: Math.max(0, r.top-20)+'px', display: 'block'}); };
     const path = n => { if (!n || n.nodeType !== 1) return ''; if (n.id) return '#' + n.id;
       let s = n.tagName.toLowerCase(); if (n.classList.length) s += '.' + [...n.classList].slice(0,3).join('.');
       const p = n.parentElement; if (!p) return s; const sib = [...p.children].filter(c => c.tagName === n.tagName);
       if (sib.length > 1) s += ':nth-of-type(' + (sib.indexOf(n)+1) + ')'; return path(p) + ' > ' + s; };
     const click = e => { e.preventDefault(); e.stopPropagation(); const el = e.target, r = el.getBoundingClientRect(), cs = getComputedStyle(el);
       const keys = ['display','position','width','height','margin','padding','color','background-color','font-family','font-size','font-weight','line-height','border','border-radius','gap','flex-direction','justify-content','align-items','grid-template-columns','box-shadow','opacity'];
       const styles = {}; keys.forEach(k => styles[k] = cs.getPropertyValue(k));
       window.webkit.messageHandlers.krill.postMessage({selector: path(el), html: el.outerHTML.slice(0, 4000), styles, rect: {x: r.left, y: r.top, w: r.width, h: r.height}, url: location.href}); };
     document.addEventListener('mousemove', move, true); document.addEventListener('click', click, true);
     window.__krillOff = () => { document.removeEventListener('mousemove', move, true); document.removeEventListener('click', click, true); box.remove(); tag.remove(); window.__krill = false; };
    })();
    """
}

/// WKUserContentController retains its handlers; break the cycle.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

extension Notification.Name { static let krillDevServerURL = Notification.Name("krill.devserver.url") }
