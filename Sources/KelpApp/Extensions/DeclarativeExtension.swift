import AppKit
import SwiftUI
import WebKit
import Core
import Agents
import WorkbenchKit

/// extension.json, as described in docs/extensions.md.
struct ExtManifest: Decodable {
    struct Contrib: Decodable {
        var panels: [ViewDef]?, editors: [ViewDef]?, commands: [ActionDef]?
        var settings: [SettingSpec]?, themes: [Theme]?, iconThemes: [IconThemeRef]?, agents: [AgentManifest]?
        var languages: [LanguageSpec]?
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
        /// Commands only: the menu bar menu it's listed in (Tools when left out).
        var menu: String?
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
    /// View definitions by "extension/view", for `ext:` tabs: only enabled extensions' (see `forget`).
    private static var views: [String: (ExtManifest, ExtManifest.ViewDef, URL)] = [:]

    /// A reload starts over (nil: every extension; uninstalled ones go); an extension turned off takes its views along.
    static func forget(_ id: String? = nil) { views = id.map { id in views.filter { $0.value.0.id != id } } ?? [:] }

    static func load(_ folder: URL, checkRequirements: Bool = true) -> (info: ExtensionInfo, contributions: Contributions) {
        let fallbackId = folder.lastPathComponent
        do {
            let own = folder.appendingPathComponent("extension.json"), vscode = folder.appendingPathComponent("package.json")
            let m = !FileManager.default.fileExists(atPath: own.path) && FileManager.default.fileExists(atPath: vscode.path)
                ? try JSONDecoder().decode(VSCodePackage.self, from: Data(contentsOf: vscode)).manifest
                : try JSONDecoder().decode(ExtManifest.self, from: Data(contentsOf: own))
            var info = ExtensionInfo(id: m.id, name: m.name, description: m.description ?? "", version: m.version ?? "", icon: m.icon ?? "puzzlepiece.extension",
                                     builtin: false, path: folder, enabled: true)
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
            c.commands.append(CommandSpec(id: a.id ?? "\(m.id).\(a.title)", title: a.title, extensionId: m.id, key: a.key, menu: a.menu) { _ in
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
        c.languages = x?.languages ?? []
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
        let value: (String) -> String? = { key in
            switch key {
            case "workspace.path": return ctx.workspace?.path ?? ""
            case "workspace.branch": return ctx.workspace?.branch ?? ""
            case "workspace.name": return ctx.workspace?.displayName ?? ""
            case "project.path": return ctx.project?.path ?? ""
            case "file": return ctx.focusedFile ?? ""
            default:
                if key.hasPrefix("setting:") { return SettingsStore.shared.value(String(key.dropFirst(8))).map(text) ?? "" }
                return key.split(separator: ".").reduce(item) { $0?[String($1)] }.map(text) ?? ""
            }
        }
        // A command gets the values as shell variables, never as text in it: $(…) or a newline in a title can't run.
        return quote ? ShellTemplate.fill(template, value) : ShellTemplate.substitute(template) { value($0) ?? "" }
    }

    /// An `open` action's URI: the extension's template with the item's values put in. A URI that runs something
    /// (terminal:, agent:) has to say so in the extension's own words, never through a value (someone else's: an issue's
    /// link field set to terminal://…?cmd=…). nil then.
    static func openURI(_ template: String, item: JSONValue?) -> String? {
        let uri = TabURI.normalize(expand(template, item: item, quote: false), cwd: IDEContext.current.workspace?.path)
        return Self.runs.contains { template.hasPrefix($0 + ":") } ? uri : openableURI(uri)
    }
    private static let runs = ["terminal", "agent"]

    /// A URI that opens something (a page, a file, a diff, a tab) rather than running a command or an agent; nil else.
    static func openableURI(_ uri: String) -> String? { runs.contains(TabURI.scheme(uri)) ? nil : uri }

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
        else if let o = a.open {
            if let u = openURI(o, item: item) { Workbench.open(u) }
            else { Banner.show(String(localized: "“\(a.title)” would run a command or an agent from its data; it opens links and files only.")) }
        }
        // Typed, not sent: `item` is a command's output (an issue's title, a PR's body), someone else's words.
        else if let p = a.agent { Workbench.editor?.newAgent(nil, prompt: expand(p, item: item, quote: false), extra: ["draft": true]) }
        else if let r = a.run {
            let cmd = expand(r, item: item, quote: true)
            Task {
                let res = await Shell.run(cmd, cwd: IDEContext.current.workspace?.path ?? folder.path)
                if res.code != 0 { Banner.show(String(localized: "\(a.title) failed: ") + String((res.stderr.isEmpty ? res.stdout : res.stderr).suffix(400)), style: .error) }
                after?()
            }
            return
        }
        after?()
    }
}

/// Runs a command the way the user's terminal would (login-shell PATH); `input` goes to its stdin. Nothing blocks a
/// thread of the cooperative pool: the pipes are read as data arrives and the exit comes from `terminationHandler`.
enum Shell {
    struct Result: Sendable { var code: Int32; var stdout: String; var stderr: String }
    static func run(_ command: String, cwd: String, input: String? = nil, timeout: TimeInterval = 60) async -> Result {
        await exec(["/bin/zsh", "-lc", command], cwd: cwd, input: input, timeout: timeout)
    }

    /// A program by path (`argv[0]`), with the same PATH and a time limit (stopped then, with what it started).
    static func exec(_ argv: [String], cwd: String = NSHomeDirectory(), input: String? = nil, timeout: TimeInterval = 60) async -> Result {
        var env = ProcessInfo.processInfo.environment; env["PATH"] = LoginPath.value
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        do {
            let r = try await Subprocess.run(argv, cwd: dir, env: env, stdin: input.map { Data($0.utf8) }, timeLimit: timeout)
            // Lossy on purpose: a tool's output with a stray byte should still show.
            return Result(code: r.status, stdout: String(decoding: r.stdout, as: UTF8.self), stderr: String(decoding: r.stderr, as: UTF8.self))
        } catch {
            return Result(code: -1, stdout: "", stderr: error.localizedDescription)
        }
    }
}
