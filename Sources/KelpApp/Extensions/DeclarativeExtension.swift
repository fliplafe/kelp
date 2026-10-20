import AppKit
import SwiftUI
import WebKit
import Core
import Agents

/// extension.json, as described in docs/extensions.md.
struct ExtManifest: Decodable {
    struct Contrib: Decodable {
        var panels: [ViewDef]?, editors: [ViewDef]?, commands: [ActionDef]?
        var settings: [SettingSpec]?, themes: [Theme]?, iconThemes: [IconThemeRef]?, agents: [AgentManifest]?
    }
    /// VS Code's own shape: the theme file is in VS Code's file icon theme format.
    struct IconThemeRef: Decodable { var id: String; var label: String?; var path: String }
    struct ViewDef: Decodable { var id: String; var title: String; var icon: String?; var list: ListDef?; var web: String? }
    struct ListDef: Decodable {
        struct StatusMap: Decodable { var field: String; var map: [String: String] }
        var command: String
        var refresh: Double?
        var title: String?, subtitle: String?, icon: String?
        var status: StatusMap?
        var empty: String?
        var actions: [ActionDef]?, toolbar: [ActionDef]?
    }
    /// A list action, toolbar button or command: exactly one of terminal / run / open / agent.
    struct ActionDef: Decodable {
        var id: String?
        var title: String
        var icon: String?, key: String?, confirm: String?
        var terminal: String?, run: String?, open: String?, agent: String?
    }
    var id: String
    var name: String
    var version: String?
    var description: String?
    var icon: String?
    /// Commands that must be on PATH (e.g. "docker"); without them the extension stays inactive.
    var requires: [String]?
    var contributes: Contrib?
}

/// A VS Code extension's package.json. Kelp uses what it understands of it: file icon themes.
struct VSCodePackage: Decodable {
    struct Contrib: Decodable { var iconThemes: [ExtManifest.IconThemeRef]? }
    var name: String, publisher: String?, displayName: String?, version: String?, description: String?
    var contributes: Contrib?

    var manifest: ExtManifest {
        ExtManifest(id: publisher.map { "\($0).\(name)" } ?? name, name: displayName ?? name, version: version, description: description,
                    icon: "paintpalette", contributes: .init(iconThemes: contributes?.iconThemes))
    }
}

@MainActor
enum DeclarativeExtension {
    /// View definitions by "extension/view", for `ext:` tabs.
    private static var views: [String: (ExtManifest, ExtManifest.ViewDef, URL)] = [:]

    static func load(_ folder: URL, builtin: Bool = false, checkRequirements: Bool = true) -> (info: ExtensionInfo, contributions: Contributions) {
        let fallbackId = folder.lastPathComponent
        do {
            let own = folder.appendingPathComponent("extension.json"), vscode = folder.appendingPathComponent("package.json")
            let m = !FileManager.default.fileExists(atPath: own.path) && FileManager.default.fileExists(atPath: vscode.path)
                ? try JSONDecoder().decode(VSCodePackage.self, from: Data(contentsOf: vscode)).manifest
                : try JSONDecoder().decode(ExtManifest.self, from: Data(contentsOf: own))
            var info = ExtensionInfo(id: m.id, name: m.name, description: m.description ?? "", version: m.version ?? "", icon: m.icon ?? "puzzlepiece.extension",
                                     builtin: builtin, path: folder, enabled: true)
            if checkRequirements, let missing = (m.requires ?? []).first(where: { (try? LoginPath.resolve($0)) == nil }) {
                info.unavailable = String(localized: "Needs `\(missing)` — not found on this Mac.")
                return (info, Contributions())
            }
            return (info, contributions(m, folder))
        } catch {
            let msg = (error as? DecodingError).map(describe) ?? error.localizedDescription
            return (ExtensionInfo(id: fallbackId, name: fallbackId, description: "", version: "", icon: "exclamationmark.triangle", builtin: false,
                                  path: folder, error: msg, enabled: true), Contributions())
        }
    }

    private static func contributions(_ m: ExtManifest, _ folder: URL) -> Contributions {
        var c = Contributions()
        let x = m.contributes
        for v in x?.panels ?? [] {
            views["\(m.id)/\(v.id)"] = (m, v, folder)
            c.panels.append(PanelSpec(id: "\(m.id).\(v.id)", title: v.title, icon: v.icon ?? m.icon ?? "puzzlepiece.extension", extensionId: m.id) {
                viewController(m, v, folder)
            })
        }
        for v in x?.editors ?? [] {
            views["\(m.id)/\(v.id)"] = (m, v, folder)
            c.editors.append(EditorSpec(id: "\(m.id).\(v.id)", title: v.title, icon: v.icon ?? m.icon ?? "puzzlepiece.extension", extensionId: m.id,
                                        uri: { _ in "ext:\(m.id)/\(v.id)" }))
        }
        for a in x?.commands ?? [] {
            c.commands.append(CommandSpec(id: a.id ?? "\(m.id).\(a.title)", title: a.title, extensionId: m.id, key: a.key) { _ in
                ExtActions.perform(a, item: nil, folder: folder)
            })
        }
        if let s = x?.settings, !s.isEmpty {
            c.settings.append(SettingsSection(id: m.id, title: m.name, icon: m.icon ?? "puzzlepiece.extension", extensionId: m.id, specs: s))
        }
        c.themes = x?.themes ?? []
        c.iconThemes = (x?.iconThemes ?? []).map {
            IconThemeSpec(id: $0.id, label: $0.label ?? $0.id, file: folder.appendingPathComponent($0.path).standardizedFileURL)
        }
        c.agents = x?.agents ?? []
        return c
    }

    static func viewInfo(_ uri: String) -> (title: String, icon: String)? {
        views[TabURI.body(uri)].map { ($0.1.title, $0.1.icon ?? $0.0.icon ?? "puzzlepiece.extension") }
    }

    /// Opens `ext:<extension>/<view>` tabs.
    static let tabProvider = TabProvider(schemes: ["ext"], extensionId: "kelp.agents") { uri in
        guard let (m, v, folder) = views[TabURI.body(uri)] else { return nil }
        return ExtViewTab(uri: uri, title: v.title, icon: v.icon ?? m.icon ?? "puzzlepiece.extension", controller: viewController(m, v, folder))
    }

    private static func viewController(_ m: ExtManifest, _ v: ExtManifest.ViewDef, _ folder: URL) -> NSViewController {
        if let list = v.list { return hosting(ExtListView(def: list, folder: folder)) }
        if let web = v.web { return ExtWebController(page: folder.appendingPathComponent(web), folder: folder) }
        let vc = NSViewController(); vc.view = NSTextField(labelWithString: String(localized: "\(m.name): view “\(v.id)” has neither list nor web."))
        return vc
    }

    private static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, let c): "Missing “\(k.stringValue)” at \(path(c))"
        case .typeMismatch(_, let c), .valueNotFound(_, let c): "Wrong type at \(path(c)): \(c.debugDescription)"
        case .dataCorrupted(let c): "Invalid JSON: \(c.underlyingError?.localizedDescription ?? c.debugDescription)"
        @unknown default: "\(e)"
        }
    }
    private static func path(_ c: DecodingError.Context) -> String { c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".") }
}

/// An extension view in the editor area.
@MainActor
final class ExtViewTab: TabContent {
    let uri: String, title: String
    let icon: NSImage?
    var onChange: (() -> Void)?
    private let controller: NSViewController
    var view: NSView { controller.view }
    init(uri: String, title: String, icon: String, controller: NSViewController) {
        self.uri = uri; self.title = title; self.icon = .symbol(icon); self.controller = controller
    }
    func focus() {}
}

// MARK: running commands and actions

@MainActor
enum ExtActions {
    /// `${Field}`, `${a.b}`, `${setting:key}`, `${workspace.path|branch|name}`, `${project.path}`, `${file}`. `quote` shell-quotes values.
    static func expand(_ template: String, item: JSONValue?, quote: Bool) -> String {
        let ctx = IDEContext.current
        var out = "", rest = Substring(template)
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            out += rest[..<open.lowerBound]
            let key = String(rest[open.upperBound..<close])
            var v: String
            switch key {
            case "workspace.path": v = ctx.workspace?.path ?? ""
            case "workspace.branch": v = ctx.workspace?.branch ?? ""
            case "workspace.name": v = ctx.workspace?.displayName ?? ""
            case "project.path": v = ctx.project?.path ?? ""
            case "file": v = ctx.focusedFile ?? ""
            default:
                if key.hasPrefix("setting:") { v = SettingsStore.shared.value(String(key.dropFirst(8))).map(text) ?? "" }
                else { v = key.split(separator: ".").reduce(item) { $0?[String($1)] }.map(text) ?? "" }
            }
            out += quote ? "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'" : v
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    static func text(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(format: d == d.rounded() ? "%.0f" : "%g", d)
        case .bool(let b): b ? "true" : "false"
        case .null: ""
        default: (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? ""
        }
    }

    static func perform(_ a: ExtManifest.ActionDef, item: JSONValue?, folder: URL, after: (() -> Void)? = nil) {
        if let q = a.confirm {
            let alert = NSAlert(); alert.messageText = expand(q, item: item, quote: false)
            alert.addButton(withTitle: a.title); alert.addButton(withTitle: String(localized: "Cancel"))
            guard runAsSheet(alert) == .alertFirstButtonReturn else { return }
        }
        if let t = a.terminal { Workbench.editor?.run(command: expand(t, item: item, quote: true), title: a.title) }
        else if let o = a.open { Workbench.open(TabURI.normalize(expand(o, item: item, quote: false), cwd: IDEContext.current.workspace?.path)) }
        else if let p = a.agent { Workbench.editor?.newAgent(nil, prompt: expand(p, item: item, quote: false)) }
        else if let r = a.run {
            let cmd = expand(r, item: item, quote: true)
            Task {
                let res = await Shell.run(cmd, cwd: IDEContext.current.workspace?.path ?? folder.path)
                if res.code != 0 { Banner.show("\(a.title) failed: " + String((res.stderr.isEmpty ? res.stdout : res.stderr).suffix(400)), style: .error) }
                after?()
            }
            return
        }
        after?()
    }
}

/// Runs a command the way the user's terminal would (login-shell PATH), off the main thread.
enum Shell {
    struct Result: Sendable { var code: Int32; var stdout: String; var stderr: String }
    static func run(_ command: String, cwd: String, timeout: TimeInterval = 60) async -> Result {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", command]
            p.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory())
            var env = ProcessInfo.processInfo.environment; env["PATH"] = LoginPath.value
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return Result(code: -1, stdout: "", stderr: error.localizedDescription) }
            // Read while it runs: a full pipe would block the process.
            async let o = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
            async let e = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
            if p.isRunning { p.terminate() }
            let (od, ed) = await (o, e)
            // Lossy on purpose: a tool's output with a stray byte should still show.
            // swiftlint:disable:next optional_data_string_conversion
            return Result(code: p.terminationStatus, stdout: String(decoding: od, as: UTF8.self), stderr: String(decoding: ed, as: UTF8.self))
        }.value
    }
}

// MARK: list views

struct ExtListView: View {
    let def: ExtManifest.ListDef
    let folder: URL
    @State private var items: [JSONValue] = []
    @State private var error: String?
    @State private var loading = false   // the spinner, after a second
    @State private var running = false   // the command hasn't answered yet (no "empty" meanwhile)
    @State private var selection: Int?
    private var bench = Workbench.shared

    init(def: ExtManifest.ListDef, folder: URL) { self.def = def; self.folder = folder }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Array((def.toolbar ?? []).enumerated()), id: \.offset) { _, a in
                    Button { ExtActions.perform(a, item: nil, folder: folder) { reload() } } label: {
                        Label(a.title, systemImage: a.icon ?? "play")
                    }
                    .buttonStyle(.borderless).help(a.title)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if let error {
                ContentUnavailableView { Label("Couldn't load", systemImage: "exclamationmark.triangle") } description: { Text(error).font(.caption).textSelection(.enabled) }
                    .frame(maxHeight: .infinity)
            } else if items.isEmpty, !running {
                ContentUnavailableView(def.empty ?? String(localized: "Nothing here"), systemImage: def.icon ?? "tray")
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        row(item).tag(i)
                            .contextMenu {
                                ForEach(Array((def.actions ?? []).enumerated()), id: \.offset) { _, a in
                                    Button { ExtActions.perform(a, item: item, folder: folder) { reload() } } label: { Label(a.title, systemImage: a.icon ?? "circle") }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { sel in
                    if let i = sel.first, items.indices.contains(i), let a = def.actions?.first { ExtActions.perform(a, item: items[i], folder: folder) { reload() } }
                }
            }
        }
        .task(id: bench.workspaceId) {
            while !Task.isCancelled {
                reload()
                guard let r = def.refresh, r > 0 else { break }
                try? await Task.sleep(for: .seconds(max(r, 1)))
            }
        }
    }

    private func row(_ item: JSONValue) -> some View {
        HStack(spacing: 8) {
            Image(systemName: def.icon.map { ExtActions.expand($0, item: item, quote: false) } ?? "circle.fill").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(ExtActions.expand(def.title ?? "${name}", item: item, quote: false)).lineLimit(1)
                if let s = def.subtitle { Text(ExtActions.expand(s, item: item, quote: false)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if let st = status(item) { StatusIcon(status: st) }
        }
    }

    private func status(_ item: JSONValue) -> AgentStatus? {
        guard let s = def.status, let v = item[s.field].map(ExtActions.text), let mapped = s.map[v] ?? s.map[v.lowercased()] else { return nil }
        switch mapped {
        case "working": return .working
        case "waiting": return .waiting
        case "done": return .done
        case "idle": return .idle
        default: return .exited
        }
    }

    private func reload() {
        let cmd = ExtActions.expand(def.command, item: nil, quote: true)
        let cwd = IDEContext.current.workspace?.path ?? folder.path
        let slow = whileSlow { loading = true }   // a spinner only for a wait you'd notice
        running = true
        Task {
            let r = await Shell.run(cmd, cwd: cwd)
            slow.cancel(); loading = false; running = false
            if r.code != 0, r.stdout.isEmpty { error = r.stderr.isEmpty ? String(localized: "Exit code \(r.code)") : String(r.stderr.suffix(600)); return }
            error = nil
            items = Self.parse(r.stdout)
        }
    }

    /// A JSON array, or one JSON object per line.
    static func parse(_ s: String) -> [JSONValue] {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("["), let d = t.data(using: .utf8), case .array(let a)? = try? JSONDecoder().decode(JSONValue.self, from: d) { return a }
        return t.split(whereSeparator: \.isNewline).compactMap { line in
            line.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }
    }
}

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
        track { Workbench.shared.workspaceId } changed: { [weak self] _ in self?.push() }
        track { SettingsStore.shared.values } changed: { [weak self] _ in self?.push() }
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
