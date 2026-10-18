import AppKit
import WebKit
import Core

/// Embedded browser: tabs per worktree, dev-server auto-open, and Design Mode (click an element →
/// its HTML, computed styles and a cropped screenshot go into the agent's prompt).
@MainActor
final class BrowserViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler, NSTextFieldDelegate, NSTabViewDelegate {
    static let shared: BrowserViewController = { let b = BrowserViewController(); _ = b.view; return b }()
    private var tabsByWorktree: [String: [WKWebView]] = [:]
    private var worktreeId: String?
    private let tabs = NSTabView()
    private let address = NSTextField()
    private let designButton = NSButton()
    private let empty = NSTextField(labelWithString: "Open a URL or run the dev server (⌃⌘R).")
    var currentSession: () -> String? = { nil }
    private var designOn = false

    override func loadView() {
        func b(_ sym: String, _ tip: String, _ sel: Selector) -> NSButton {
            let x = NSButton(image: NSImage(systemSymbolName: sym, accessibilityDescription: tip)!, target: self, action: sel)
            x.bezelStyle = .texturedRounded; x.toolTip = tip; return x
        }
        address.placeholderString = "localhost:3000"; address.delegate = self; address.target = self; address.action = #selector(go)
        address.lineBreakMode = .byTruncatingTail
        designButton.setButtonType(.pushOnPushOff); designButton.bezelStyle = .texturedRounded
        designButton.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Design Mode"); designButton.title = "Design Mode"
        designButton.imagePosition = .imageLeading; designButton.target = self; designButton.action = #selector(toggleDesign)
        designButton.toolTip = "Click an element to send its HTML, CSS and a screenshot to the agent"
        let bar = NSStackView(views: [b("chevron.left", "Back", #selector(back)), b("chevron.right", "Forward", #selector(forward)),
                                      b("arrow.clockwise", "Reload", #selector(reload)), address, designButton,
                                      b("plus", "New Tab", #selector(newTab)), b("safari", "Open in Safari", #selector(openExternal))])
        bar.spacing = 6; bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabs.tabViewType = .topTabsBezelBorder; tabs.delegate = self
        empty.textColor = .secondaryLabelColor; empty.alignment = .center
        let body = NSView()
        for v in [tabs, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(v) }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: body.topAnchor), tabs.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: body.leadingAnchor), tabs.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: body.centerXAnchor), empty.centerYAnchor.constraint(equalTo: body.centerYAnchor),
        ])
        view = pinned(bar: bar, body: body)
        NotificationCenter.default.addObserver(forName: .krillDevServerURL, object: nil, queue: .main) { [weak self] n in
            guard let wid = n.userInfo?["worktree"] as? String, let url = n.userInfo?["url"] as? String else { return }
            MainActor.assumeIsolated { self?.open(url, in: wid, reuse: true) }
        }
    }

    func show(worktree id: String?) {
        worktreeId = id
        tabs.tabViewItems.forEach(tabs.removeTabViewItem)
        for w in tabsByWorktree[id ?? ""] ?? [] { addItem(w) }
        empty.isHidden = tabs.numberOfTabViewItems > 0
        syncAddress()
    }

    private var web: WKWebView? { tabs.selectedTabViewItem?.view as? WKWebView }

    private func makeWeb() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakHandler(self), name: "krill")
        cfg.preferences.isElementFullscreenEnabled = true
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = self; w.allowsBackForwardNavigationGestures = true; w.isInspectable = true
        return w
    }
    private func addItem(_ w: WKWebView) {
        let item = NSTabViewItem(identifier: ObjectIdentifier(w).hashValue); item.view = w
        item.label = w.title.flatMap { $0.isEmpty ? nil : $0 } ?? w.url?.host ?? "New Tab"
        tabs.addTabViewItem(item); tabs.selectTabViewItem(item)
    }

    /// Opens `url` in this worktree's browser (reusing a tab on the same host:port if asked).
    func open(_ raw: String, in wid: String? = nil, reuse: Bool = false) {
        guard let wid = wid ?? worktreeId else { return }
        let s = raw.contains("://") ? raw : (raw.hasPrefix("localhost") || raw.first?.isNumber == true ? "http://" : "https://") + raw
        guard let url = URL(string: s) else { NSSound.beep(); return }
        var list = tabsByWorktree[wid] ?? []
        let w: WKWebView
        if reuse, let existing = list.first(where: { $0.url?.host == url.host && $0.url?.port == url.port }) { w = existing }
        else if !reuse, wid == worktreeId, let cur = web { w = cur }
        else { w = makeWeb(); list.append(w); tabsByWorktree[wid] = list; if wid == worktreeId { addItem(w) } }
        w.load(URLRequest(url: url))
        if wid == worktreeId { empty.isHidden = true; if let i = tabs.tabViewItems.firstIndex(where: { $0.view === w }) { tabs.selectTabViewItem(at: i) } }
    }

    @objc private func go() { open(address.stringValue) }
    @objc private func back() { web?.goBack() }
    @objc private func forward() { web?.goForward() }
    @objc private func reload() { web?.reload() }
    @objc private func openExternal() { if let u = web?.url { NSWorkspace.shared.open(u) } }
    @objc func newTab() {
        guard let wid = worktreeId else { return }
        let w = makeWeb(); tabsByWorktree[wid, default: []].append(w); addItem(w); empty.isHidden = true
        view.window?.makeFirstResponder(address)
    }
    @objc func closeTab() {
        guard let wid = worktreeId, let w = web, let item = tabs.selectedTabViewItem else { return }
        tabsByWorktree[wid]?.removeAll { $0 === w }; tabs.removeTabViewItem(item); empty.isHidden = tabs.numberOfTabViewItems > 0
    }

    func tabView(_ t: NSTabView, didSelect item: NSTabViewItem?) { syncAddress(); designOn = false; designButton.state = .off }
    private func syncAddress() { address.stringValue = web?.url?.absoluteString ?? "" }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        if let item = tabs.tabViewItems.first(where: { $0.view === w }) { item.label = w.title.flatMap { $0.isEmpty ? nil : $0 } ?? w.url?.host ?? "Page" }
        if w === web { syncAddress() }
        if designOn && w === web { w.evaluateJavaScript(Self.designJS) }
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { showError(w, e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { showError(w, e) }
    private func showError(_ w: WKWebView, _ e: Error) {
        let msg = (e as NSError).localizedDescription.replacingOccurrences(of: "<", with: "&lt;")
        w.loadHTMLString("<html><body style='font:14px -apple-system;color:#888;display:flex;height:90vh;align-items:center;justify-content:center;text-align:center'><div><b>Can't open this page</b><br>\(msg)<br><br>Is the dev server running?</div></body></html>", baseURL: nil)
    }

    // MARK: Design Mode
    @objc func toggleDesign() {
        designOn.toggle(); designButton.state = designOn ? .on : .off
        web?.evaluateJavaScript(designOn ? Self.designJS : "window.__krillOff && window.__krillOff()")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any], let w = web else { return }
        let r = d["rect"] as? [String: Double] ?? [:]
        let rect = CGRect(x: r["x"] ?? 0, y: r["y"] ?? 0, width: max(1, r["w"] ?? 1), height: max(1, r["h"] ?? 1)).insetBy(dx: -8, dy: -8)
        let cfg = WKSnapshotConfiguration(); cfg.rect = rect.intersection(w.bounds)
        w.takeSnapshot(with: cfg) { [weak self] img, _ in
            MainActor.assumeIsolated { self?.sendDesign(d, image: img) }
        }
    }

    /// Dev aid for snapshot runs: synthesize a Design Mode click.
    func debugClick(_ selector: String) {
        web?.evaluateJavaScript("document.querySelector('\(selector)').dispatchEvent(new MouseEvent('click', {bubbles: true}))")
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
        Change: 
        """
        if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT"] != nil { print("DESIGN-MESSAGE\n" + msg) }
        guard let sid = currentSession() else {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(msg, forType: .string)
            let a = NSAlert(); a.messageText = "Copied element context"; a.informativeText = "No agent is focused in this worktree, so the element details were copied to the clipboard."
            Task { _ = await runSheet(a) }; return
        }
        Task { await AppModel.shared.call("session.send", .obj(["id": .string(sid), "text": .string(msg), "enter": false])) }
        (NSApp.delegate as? AppDelegate)?.openSession(sid)
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
