import AppKit
import Core

/// Clone a repository by URL, in a sheet that does the work in place: git's progress, its error in the sheet, and
/// Cancel stops it and removes the half-made folder.
@MainActor
final class CloneSheet: SheetController, NSPathControlDelegate {
    private let field = NSTextField()
    private let place = NSPathControl()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let go = NSButton(), cancel = NSButton()
    private var running: String?
    private static var shown: CloneSheet?

    /// `start`: filled in and begun at once (the snapshot dev aid; a background app's sheet gets no keys).
    static func show(start text: String? = nil) {
        let s = CloneSheet()
        guard s.begin(ended: { shown = nil }) else { return }
        shown = s
        if let text { s.field.stringValue = text; s.start() }
    }

    private init() {
        super.init(width: 480)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Where clones go: the last place used, else next to the newest project, else ~/Developer or home.
    private static var parent: URL {
        if let s = UserDefaults.standard.string(forKey: "newProject.parent"), FileManager.default.fileExists(atPath: s) { return URL(fileURLWithPath: s) }
        if let r = AppModel.shared.repos.last(where: { !$0.path.hasPrefix(Paths.root.path) }) { return URL(fileURLWithPath: r.path).deletingLastPathComponent() }
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : FileManager.default.homeDirectoryForCurrentUser
    }

    private func build() {
        let title = NSTextField(labelWithString: String(localized: "Clone a Repository"))
        title.font = .boldSystemFont(ofSize: 13)
        field.placeholderString = "https://github.com/owner/repo or git@…"
        field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        place.pathStyle = .popUp; place.url = Self.parent; place.delegate = self; place.allowedTypes = ["public.folder"]
        let grid = NSGridView(views: [[NSTextField(labelWithString: String(localized: "URL:")), field],
                                      [NSTextField(labelWithString: String(localized: "Clone into:")), place]])
        grid.column(at: 0).xPlacement = .trailing; grid.rowSpacing = 10; grid.columnSpacing = 8
        bar.style = .bar; bar.isIndeterminate = true; bar.isHidden = true; bar.minValue = 0; bar.maxValue = 100
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11); status.isHidden = true
        status.preferredMaxLayoutWidth = 430
        go.title = String(localized: "Clone"); go.bezelStyle = .push; go.keyEquivalent = "\r"; go.target = self; go.action = #selector(start)
        cancel.title = String(localized: "Cancel"); cancel.bezelStyle = .push; cancel.keyEquivalent = "\u{1b}"; cancel.target = self; cancel.action = #selector(stop)
        let buttons = NSStackView(views: [NSView(), cancel, go]); buttons.spacing = 8
        let stack = NSStackView(views: [title, grid, bar, status, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [bar, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        window?.contentView = stack
        window?.initialFirstResponder = field
    }

    func pathControl(_ c: NSPathControl, willDisplay panel: NSOpenPanel) {
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
    }

    /// A line git printed while cloning (`event.clone`): shown if it's this sheet's clone.
    static func cloneProgress(id: String?, line: String?) {
        if let s = shown, let id, id == s.running, let line { s.progress(line) }
    }

    /// "Receiving objects:  45% (450/1000)" fills the bar; the line itself says what's happening.
    private func progress(_ line: String) {
        status.isHidden = false; status.textColor = .secondaryLabelColor; status.stringValue = line
        if let m = line.firstMatch(of: #/(\d+)%/#), let pct = Double(m.1) { bar.isIndeterminate = false; bar.doubleValue = pct }
    }

    private func busy(_ on: Bool) {
        field.isEnabled = !on; place.isEnabled = !on; go.isEnabled = !on
        bar.isHidden = !on; if on { bar.isIndeterminate = true; bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
    }

    @objc private func start() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), parent = place.url?.path ?? Self.parent.path
        guard !text.isEmpty else { NSSound.beep(); return }
        let id = UUID().uuidString
        running = id; busy(true)
        status.isHidden = false; status.textColor = .secondaryLabelColor
        status.stringValue = String(localized: "Connecting…")
        Task {
            let r = await AppModel.shared.tryCall(RepoClone(url: text, parent: parent, id: id))
            running = nil; busy(false)
            if let e = r.error {
                if e == "Clone cancelled." { close(); return }
                status.textColor = .systemRed; status.stringValue = e; return
            }
            UserDefaults.standard.set(parent, forKey: "newProject.parent")
            close()
            if let path = r.value?.path { Workbench.addProject(path: path) }   // on screen
        }
    }

    @objc private func stop() {
        if let id = running { status.stringValue = String(localized: "Cancelling…"); Task { await AppModel.shared.call(RepoCloneCancel(id: id)) }; return }
        close()
    }
}
