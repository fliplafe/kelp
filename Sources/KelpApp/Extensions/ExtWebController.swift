import AppKit
import SwiftUI
import WebKit
import Core
import Agents
import WorkbenchKit

// MARK: web views

/// An extension's HTML page with `window.kelp` (exec, terminal, open, agent, settings, workspace).
@MainActor
final class ExtWebController: NSViewController, WKScriptMessageHandler {
    private let page: URL, folder: URL
    private var web: WKWebView!
    init(page: URL, folder: URL) { self.page = page; self.folder = folder; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakHandler(self), name: "kelp")
        cfg.userContentController.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: cfg); web.isInspectable = true
        web.setValue(false, forKey: "drawsBackground")
        view = web
        web.loadFileURL(page, allowingReadAccessTo: folder)
        track(owner: self) { Workbench.shared.workspaceId } changed: { [weak self] _ in self?.push() }
        track(owner: self) { SettingsStore.shared.values } changed: { [weak self] _ in self?.push() }
    }

    private func push() {
        let ctx = IDEContext.current
        let ws: JSONValue = .obj(["name": .string(ctx.workspace?.displayName ?? ""), "path": .string(ctx.workspace?.path ?? ""),
                                  "branch": .string(ctx.workspace?.branch ?? ""), "project": .string(ctx.project?.name ?? "")])
        let settings = JSONValue.object(SettingsStore.shared.values)
        guard let w = try? String(data: JSONEncoder().encode(ws), encoding: .utf8), let s = try? String(data: JSONEncoder().encode(settings), encoding: .utf8) else { return }
        web.evaluateJavaScript("window.kelp && window.kelp.__update(\(w), \(s))")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        // The handler is visible to every frame, whatever it loaded: only the extension's own page may run commands.
        guard m.frameInfo.isMainFrame, let u = m.frameInfo.request.url, u.isFileURL,
              u.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") else { return }
        guard let d = m.body as? [String: Any], let op = d["op"] as? String else { return }
        let id = d["id"] as? Int ?? 0, arg = d["arg"] as? String ?? ""
        let ctx = IDEContext.current
        switch op {
        case "exec":
            Task {
                let r = await Shell.run(arg, cwd: ctx.workspace?.path ?? folder.path)
                reply(id, .obj(["code": .int(Int(r.code)), "stdout": .string(r.stdout), "stderr": .string(r.stderr)]))
            }
        case "terminal": Workbench.editor?.run(command: arg, title: d["title"] as? String); reply(id, .null)
        case "open": Workbench.open(TabURI.normalize(arg, cwd: ctx.workspace?.path)); reply(id, .null)
        case "agent": Workbench.editor?.newAgent(nil, prompt: arg); reply(id, .null)
        case "settings.get": reply(id, SettingsStore.shared.value(arg) ?? .null)
        case "settings.set":
            let v = (d["value"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            SettingsStore.shared.set(arg, v); reply(id, .null)
        default: reply(id, .null)
        }
        if op == "ready" { push() }
    }

    private func reply(_ id: Int, _ v: JSONValue) {
        guard let s = try? String(data: JSONEncoder().encode(v), encoding: .utf8) else { return }
        web.evaluateJavaScript("window.kelp.__resolve(\(id), \(s))")
    }

    static let bridge = """
    (() => {
      let n = 0; const pending = {}; const listeners = {settings: [], workspace: []};
      const call = (op, arg, extra) => new Promise(res => { const id = ++n; pending[id] = res;
        window.webkit.messageHandlers.kelp.postMessage(Object.assign({op, arg, id}, extra || {})); });
      window.kelp = {
        workspace: {}, exec: c => call('exec', c), terminal: (c, o) => call('terminal', c, {title: o && o.title}),
        open: u => call('open', u), agent: p => call('agent', p),
        settings: { get: k => call('settings.get', k), set: (k, v) => call('settings.set', k, {value: JSON.stringify(v)}) },
        on: (ev, cb) => (listeners[ev] = listeners[ev] || []).push(cb),
        __resolve: (id, v) => { const r = pending[id]; delete pending[id]; r && r(v); },
        __update: (ws, settings) => { window.kelp.workspace = ws; listeners.workspace.forEach(f => f(ws)); listeners.settings.forEach(f => f(settings)); }
      };
      document.addEventListener('DOMContentLoaded', () => window.webkit.messageHandlers.kelp.postMessage({op: 'ready', id: 0}));
    })();
    """
}
