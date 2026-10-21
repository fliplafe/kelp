import AppKit
import Core
import WorkbenchKit

/// The Run menu: the project's commands from `.kelp.yaml` (⌘R run, ⌘U test, ⌘. stops; without them, the focused
/// file's language's), each in a tab of its own, opened behind what you're doing; when it ends, a banner says how, with
/// the way to its output. A project's commands run only after you trust its file (and again when the file changes).
@MainActor
final class ScriptsMenu: NSObject, NSMenuDelegate {
    static let shared = ScriptsMenu()
    private var cached: [String: [ScriptsList.Script]] = [:]   // workspace → its commands, for the menu
    private var setupCommand: [String: String] = [:]
    private var runs: [String: (workspace: String, name: String)] = [:]   // session → what it runs
    private var watching = false

    // MARK: menu

    /// The Run menu's fixed items are commands (scripts.run, .test, .stop, .edit); the project's other commands fill in when it opens.
    func menuNeedsUpdate(_ m: NSMenu) {
        let wid = Workbench.shared.workspaceId
        // Between the two separators: setup and the commands other than run/test.
        let seps = m.items.indices.filter { m.items[$0].isSeparatorItem }
        if seps.count >= 2 { for i in stride(from: seps[1] - 1, to: seps[0], by: -1) { m.removeItem(at: i) } }
        var at = (seps.first ?? 2) + 1
        let extra = (wid.flatMap { cached[$0] } ?? []).filter { !["run", "test"].contains($0.name) }.map(\.name)
        for name in (wid.flatMap { setupCommand[$0] } != nil ? ["setup"] : []) + extra {
            let i = NSMenuItem(title: name.prefix(1).uppercased() + name.dropFirst(), action: #selector(runNamed(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = name
            m.insertItem(i, at: at); at += 1
        }
        if let wid { Task { await load(wid) } }   // next time it's current
    }

    @discardableResult private func load(_ wid: String) async -> ScriptsList.Result? {
        guard let r = try? await AppModel.shared.client?.call(ScriptsList(worktreeId: wid)) else { return nil }
        cached[wid] = r.scripts
        setupCommand[wid] = r.setup
        return r
    }

    /// Something the Run menu started in this workspace is still running (Run › Stop).
    var canStop: Bool {
        guard let wid = Workbench.shared.workspaceId else { return false }
        return runs.contains { $0.value.workspace == wid && AppModel.shared.session($0.key)?.status != .exited }
    }

    @objc private func runNamed(_ i: NSMenuItem) { (i.representedObject as? String).map(run) }

    // MARK: running

    func run(_ name: String) {
        guard let wid = Workbench.shared.workspaceId else { NSSound.beep(); return }
        watch()
        Task {
            guard let info = await load(wid) else { return }
            let scripts = cached[wid] ?? []
            guard name == "setup" || scripts.contains(where: { $0.name == name }) else {
                // No project command: ⌘R runs the focused file, ⌘U its test at the cursor, when its language says how.
                if let t = Workbench.editor?.focusedContent as? FileTab, ["run", "test"].contains(name), t.language?[command: name] != nil {
                    runFile(t, name); return
                }
                Banner.show(String(localized: "This project has no “\(name)” command. Add one to .kelp.yaml (\(name): the command)."),
                            action: (String(localized: "Edit Commands"), { [weak self] in self?.edit() }))
                return
            }
            if !info.trusted {
                // A snapshot run takes clicks and keys from its environment (DevAids): anyone could start one that presses
                // Trust, so that window never trusts anything.
                guard ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] == nil else { return }
                guard await askTrust(info) else { return }
                // The digest of the text shown: a file changed since (an agent, a pull) isn't trusted unseen.
                guard await AppModel.shared.call(ScriptsTrust(worktreeId: wid, digest: info.digest)) != nil else { return }
            }
            await start(wid, name, ScriptsRun(worktreeId: wid, name: name))
        }
    }

    /// Run File / Test at Cursor: the file's language's `run` / `test`, run like the project's commands. Languages come
    /// from extensions the user installed, so there's no trust question.
    func runFile(_ t: FileTab, _ name: String) {
        guard let wid = Workbench.shared.workspaceId else { NSSound.beep(); return }
        watch()
        Task {
            guard let cmd = await t.command(name) else { return }
            let title = "\(name) \(t.title)"
            await start(wid, title, SessionCreate(worktreeId: wid, command: cmd, title: title))
        }
    }

    /// Again: start over, like Xcode's Run (the last run's tab gives way to the new one).
    private func start<M: RPCMethod>(_ wid: String, _ name: String, _ method: M) async where M.Result == Session {
        for (sid, r) in runs where r.workspace == wid && r.name == name {
            runs[sid] = nil
            if AppModel.shared.session(sid)?.status != .exited { await AppModel.shared.call(SessionKill(id: sid)) }
            Workbench.closeTab(uri: TabURI.session(sid))
        }
        guard let sid = await AppModel.shared.call(method)?.id else { return }
        runs[sid] = (wid, name)
        await AppModel.shared.refresh()
        // Below what you're doing, like a console; the keys stay where they were.
        if wid == Workbench.shared.workspaceId { Workbench.open(TabURI.session(sid), split: .down, workspace: wid, focus: false) }
        else { Workbench.window?.editors.openInBackground(TabURI.session(sid), workspace: wid) }
    }

    func stop() {
        guard let wid = Workbench.shared.workspaceId else { return }
        for (sid, r) in runs where r.workspace == wid && AppModel.shared.session(sid)?.status != .exited {
            Task { await AppModel.shared.call(SessionKill(id: sid)) }
        }
    }

    /// The first time a project's commands would run: everything trusting the file allows (commands, the agents and links
    /// a new workspace gets, the prompts it puts in agents' mouths), and whose it is.
    private func askTrust(_ info: ScriptsList.Result) async -> Bool {
        let a = NSAlert()
        a.messageText = String(localized: "Run this project's commands?")
        a.informativeText = String(localized: "\((info.file as NSString).abbreviatingWithTildeInPath) asks Kelp to run these as you, in the workspace's folder. ")
            + String(localized: "Trust it only if you know where this project comes from. Kelp asks again if the file changes.")
        a.accessoryView = Self.trustText(info)
        a.addButton(withTitle: String(localized: "Trust and Run")); a.addButton(withTitle: String(localized: "Cancel"))
        return await runSheet(a) == .alertFirstButtonReturn
    }

    /// The file's effects as the file spells them, scrollable when long.
    static func trustText(_ info: ScriptsList.Result) -> NSView {
        var lines: [String] = []
        if let s = info.setup { lines.append("setup: \(s)") }
        for s in info.scripts { lines.append("\(s.name): \(s.command)") }
        if !info.tabs.isEmpty { lines.append("tabs: " + info.tabs.joined(separator: ", ")) }
        if !info.shared.isEmpty { lines.append("shared: " + info.shared.joined(separator: ", ")) }
        if let c = info.issueCommand { lines.append("issueCommand: \(c)") }
        for (k, v) in info.recipes.sorted(by: { $0.key < $1.key }) { lines.append("recipe.\(k): \(v)") }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 10))
        text.string = lines.joined(separator: "\n"); text.isEditable = false; text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: min(220, CGFloat(max(lines.count, 1)) * 16 + 8)))
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        return scroll
    }

    /// How a run ended, said once: failed (with its output a click away) or finished.
    private func watch() {
        guard !watching else { return }
        watching = true
        track(owner: self) { AppModel.shared.sessions.filter { $0.status == .exited } } changed: { [weak self] ended in
            guard let self else { return }
            for s in ended {
                guard let r = runs.removeValue(forKey: s.id) else { continue }
                let name = "“\(r.name)”"
                let show = (String(localized: "Show Output"), { Workbench.focus(session: s.id) })
                if s.summary.hasPrefix("Ended with an error") {
                    Banner.show(String(localized: "\(name) failed \(s.summary.replacingOccurrences(of: "Ended with an error ", with: ""))"), style: .error, action: show)
                } else { Banner.show(String(localized: "\(name) finished"), action: show) }
            }
        }
    }

    /// The project's .kelp.yaml in a tab (started with the keys it knows, if there isn't one).
    func edit() {
        guard let w = AppModel.shared.worktree(Workbench.shared.workspaceId) else { NSSound.beep(); return }
        let path = (AppModel.shared.repo(w.repoId)?.path ?? w.path) + "/.kelp.yaml"
        if !FileManager.default.fileExists(atPath: path) {
            try? """
            # Kelp's Run menu runs these in the workspace's folder (Kelp asks before the first run).
            # run: npm run dev
            # test: npm test
            # lint: npm run lint
            # script.deploy: ./scripts/deploy.sh
            # setup: npm install          (also runs in each new worktree)

            """.write(toFile: path, atomically: true, encoding: .utf8)
        }
        Workbench.open(TabURI.file(path))
    }
}
