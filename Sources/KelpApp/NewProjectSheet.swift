import AppKit
import Core

/// Add Project's other two choices, each a sheet that does the work in place: clone by URL (git's progress, its error
/// in the sheet, Cancel stops it and removes the half-made folder) or a new empty project (a folder with `git init`).
@MainActor
final class NewProjectSheet: NSWindowController, NSPathControlDelegate {
    enum Kind { case clone, create, remote }
    private let kind: Kind
    private let field = NSTextField()
    /// Remote: the host, as after `ssh` (the hosts in ~/.ssh/config to pick from).
    private let host = NSComboBox()
    private let place = NSPathControl()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let go = NSButton(), cancel = NSButton()
    private var running: String?
    private var observer: Any?
    private static var shown: NewProjectSheet?

    /// `start`: filled in and begun at once (the snapshot dev aid; a background app's sheet gets no keys).
    static func show(_ kind: Kind, start text: String? = nil) {
        guard let w = Workbench.window?.window ?? NSApp.mainWindow else { return }
        let s = NewProjectSheet(kind)
        guard let sheet = s.window else { return }
        shown = s
        w.beginSheet(sheet) { _ in shown = nil }
        if let text {   // remote: "host:/path"
            let hp = text.split(separator: ":", maxSplits: 1).map(String.init)
            if kind == .remote, hp.count == 2 { s.host.stringValue = hp[0]; s.field.stringValue = hp[1] } else { s.field.stringValue = text }
            s.start()
        }
    }

    private init(_ kind: Kind) {
        self.kind = kind
        super.init(window: NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 10), styleMask: [.titled], backing: .buffered, defer: true))
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Where new projects go: the last place used, else next to the newest project, else ~/Developer or home.
    private static var parent: URL {
        if let s = UserDefaults.standard.string(forKey: "newProject.parent"), FileManager.default.fileExists(atPath: s) { return URL(fileURLWithPath: s) }
        if let r = AppModel.shared.repos.last(where: { !$0.path.hasPrefix(Paths.root.path) }) { return URL(fileURLWithPath: r.path).deletingLastPathComponent() }
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : FileManager.default.homeDirectoryForCurrentUser
    }

    private func build() {
        let clone = kind == .clone, remote = kind == .remote
        let title = NSTextField(labelWithString: remote ? String(localized: "Open a Project over SSH") : clone ? String(localized: "Clone a Repository") : String(localized: "New Project"))
        title.font = .boldSystemFont(ofSize: 13)
        field.placeholderString = remote ? "~/code/app" : clone ? "https://github.com/owner/repo or git@…" : "my-app"
        field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        place.pathStyle = .popUp; place.url = Self.parent; place.delegate = self; place.allowedTypes = ["public.folder"]
        host.addItems(withObjectValues: Self.sshHosts()); host.placeholderString = String(localized: "user@server or a Host from ~/.ssh/config")
        host.completes = true
        let grid = remote
            ? NSGridView(views: [[NSTextField(labelWithString: String(localized: "Host:")), host], [NSTextField(labelWithString: String(localized: "Folder there:")), field]])
            : NSGridView(views: [[NSTextField(labelWithString: clone ? String(localized: "URL:") : String(localized: "Name:")), field],
                                 [NSTextField(labelWithString: clone ? String(localized: "Clone into:") : String(localized: "Create in:")), place]])
        grid.column(at: 0).xPlacement = .trailing; grid.rowSpacing = 10; grid.columnSpacing = 8
        bar.style = .bar; bar.isIndeterminate = true; bar.isHidden = true; bar.minValue = 0; bar.maxValue = 100
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11); status.isHidden = true
        status.preferredMaxLayoutWidth = 430
        go.title = remote ? String(localized: "Open") : clone ? String(localized: "Clone") : String(localized: "Create"); go.bezelStyle = .push; go.keyEquivalent = "\r"; go.target = self; go.action = #selector(start)
        cancel.title = String(localized: "Cancel"); cancel.bezelStyle = .push; cancel.keyEquivalent = "\u{1b}"; cancel.target = self; cancel.action = #selector(stop)
        let buttons = NSStackView(views: [NSView(), cancel, go]); buttons.spacing = 8
        let stack = NSStackView(views: [title, grid, bar, status, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [bar, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        window?.contentView = stack
        window?.initialFirstResponder = remote ? host : field
        if remote {
            let note = NSTextField(wrappingLabelWithString: String(localized: "Agents and terminals run there, and git too, over one SSH connection. ")
                                   + String(localized: "The agents you use must be installed on that machine. Files open read-only."))
            note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11); note.preferredMaxLayoutWidth = 430
            (window?.contentView as? NSStackView)?.insertArrangedSubview(note, at: 2)
        }
        observer = NotificationCenter.default.addObserver(forName: .kelpClone, object: nil, queue: .main) { [weak self] n in
            let id = n.userInfo?["id"] as? String, line = n.userInfo?["line"] as? String
            MainActor.assumeIsolated { if let self, id == self.running, let line { self.progress(line) } }
        }
    }

    /// The `Host` names in ~/.ssh/config (patterns left out).
    static func sshHosts() -> [String] {
        let text = (try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let w = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard w.first?.lowercased() == "host" else { return [] }
            return w.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
        }
    }

    func pathControl(_ c: NSPathControl, willDisplay panel: NSOpenPanel) {
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
    }

    /// "Receiving objects:  45% (450/1000)" fills the bar; the line itself says what's happening.
    private func progress(_ line: String) {
        status.isHidden = false; status.textColor = .secondaryLabelColor; status.stringValue = line
        if let m = line.firstMatch(of: #/(\d+)%/#), let pct = Double(m.1) { bar.isIndeterminate = false; bar.doubleValue = pct }
    }

    private func busy(_ on: Bool) {
        field.isEnabled = !on; place.isEnabled = !on; host.isEnabled = !on; go.isEnabled = !on
        bar.isHidden = !on; if on { bar.isIndeterminate = true; bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
    }

    @objc private func start() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), parent = place.url?.path ?? Self.parent.path
        guard !text.isEmpty else { NSSound.beep(); return }
        let id = UUID().uuidString
        running = id; busy(true)
        status.isHidden = false; status.textColor = .secondaryLabelColor
        status.stringValue = kind == .create ? String(localized: "Creating…") : String(localized: "Connecting…")
        Task {
            if kind == .remote {
                let r = await AppModel.shared.tryCall("repo.addRemote", .obj(["host": .string(host.stringValue), "path": .string(text)]))
                running = nil; busy(false)
                if let e = r.error { status.textColor = .systemRed; status.stringValue = e; return }
                close()
                await AppModel.shared.refresh()
                if let rid = r.value?["id"]?.string, let repo = AppModel.shared.repo(rid), let w = AppModel.shared.workspaces(of: repo).first {
                    Workbench.show(workspace: w.id)
                }
                return
            }
            let r = kind == .clone
                ? await AppModel.shared.tryCall("repo.clone", .obj(["url": .string(text), "parent": .string(parent), "id": .string(id)]))
                : await AppModel.shared.tryCall("repo.create", .obj(["name": .string(text), "parent": .string(parent)]))
            running = nil; busy(false)
            if let e = r.error {
                if e == "Clone cancelled." { close(); return }
                status.textColor = .systemRed; status.stringValue = e; return
            }
            UserDefaults.standard.set(parent, forKey: "newProject.parent")
            close()
            if let path = r.value?["path"]?.string { Workbench.addProject(path: path) }   // on screen
        }
    }

    @objc private func stop() {
        if let id = running { status.stringValue = String(localized: "Cancelling…"); Task { await AppModel.shared.call("repo.cloneCancel", .obj(["id": .string(id)])) }; return }
        close()
    }

    override func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let w = window { w.sheetParent?.endSheet(w) }
    }
}

extension Notification.Name { static let kelpClone = Notification.Name("kelp.clone") }
