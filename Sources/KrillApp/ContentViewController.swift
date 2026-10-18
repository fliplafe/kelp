import AppKit
import Core

/// Right-hand side: the selected workspace (its own tabs), or a welcome screen; a status bar along the bottom.
@MainActor
final class ContentViewController: NSViewController {
    private var workspaces: [String: WorkspaceViewController] = [:]
    private(set) var workspace: WorkspaceViewController?
    var worktreeId: String? { workspace?.worktree.id }
    private let host = NSView()
    private let statusBar = StatusBar()
    private var welcome: NSView?

    override func loadView() {
        let v = NSView()
        for x in [host, statusBar] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: v.topAnchor), host.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: v.trailingAnchor), host.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: v.leadingAnchor), statusBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
        showWelcome()
    }

    func show(worktree id: String?) {
        if let id, id == worktreeId { return }
        if let old = workspace { old.suspend(); old.view.removeFromSuperview() }
        workspace = nil
        guard let id, let w = AppModel.shared.worktree(id) else { showWelcome(); statusBar.update(nil); return }
        welcome?.removeFromSuperview(); welcome = nil
        let vc: WorkspaceViewController
        if let cached = workspaces[id] { vc = cached } else { vc = WorkspaceViewController(worktree: w); workspaces[id] = vc; addChild(vc) }
        workspace = vc
        pin(vc.view)
        vc.refresh()
        statusBar.update(vc.worktree)
    }

    /// Daemon state changed: keep the visible workspace and the status bar in step.
    func refresh() {
        if let w = workspace, AppModel.shared.worktree(w.worktree.id) == nil { show(worktree: nil) }   // removed elsewhere
        workspace?.refresh()
        if workspace == nil { showWelcome() }
        statusBar.update(workspace?.worktree)
    }

    private func pin(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: host.topAnchor), v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: host.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
    }

    private func showWelcome() {
        let hasRepos = !AppModel.shared.repos.isEmpty
        if let w = welcome as? WelcomeView, w.hasRepos == hasRepos { return }
        welcome?.removeFromSuperview()
        let w = WelcomeView(hasRepos: hasRepos)
        welcome = w; pin(w)
    }

    /// Menu commands that name a tab kind.
    func select(named n: String) {
        guard let ws = workspace else { NSSound.beep(); return }
        switch n {
        case "Review", "Changes": ws.open(.changes)
        case "Files": ws.open(.files)
        case "Browser": ws.open(.browser)
        case "Tasks": ws.open(.tasks)
        default: break
        }
    }

    var files: FilesViewController? { workspace?.filesController }
    var browser: BrowserViewController? { workspace?.browserController }
    var diff: DiffViewController? { workspace?.diffController }
}

/// No workspace selected: first-run guidance or a nudge to create one.
@MainActor
final class WelcomeView: NSView {
    let hasRepos: Bool
    init(hasRepos: Bool) {
        self.hasRepos = hasRepos
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: hasRepos ? "square.stack.3d.up" : "folder.badge.plus", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light); icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: hasRepos ? "Start a workspace" : "Welcome to Krill")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: hasRepos
            ? "A workspace is a task with its own branch and checkout. Describe the task, pick an agent, and it starts working — run several side by side."
            : "Add a git repository. Each task then gets its own workspace — a branch and checkout where an agent works without touching your main copy.")
        body.alignment = .center; body.textColor = .secondaryLabelColor; body.font = .systemFont(ofSize: 13)
        let button = NSButton(title: hasRepos ? "New Workspace…" : "Add Repository…", target: NSApp.delegate,
                              action: hasRepos ? #selector(AppDelegate.newWorktree) : #selector(AppDelegate.addProject))
        button.bezelStyle = .push; button.keyEquivalent = "\r"; button.controlSize = .large
        let shortcut = NSTextField(labelWithString: hasRepos ? "⌘N" : "⌘O"); shortcut.textColor = .tertiaryLabelColor; shortcut.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [icon, title, body, button, shortcut])
        stack.orientation = .vertical; stack.spacing = 10; stack.setCustomSpacing(16, after: body); stack.setCustomSpacing(4, after: button)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
                                     body.widthAnchor.constraint(equalToConstant: 420)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Bottom strip: where you are (branch, PR) and what every agent is doing; click a count to jump there.
@MainActor
final class StatusBar: NSView {
    private let location = NSTextField(labelWithString: "")
    private let counts = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        location.font = .monospacedSystemFont(ofSize: 11, weight: .regular); location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle
        let sep = NSBox(); sep.boxType = .separator
        counts.spacing = 14
        for v in [location, counts, sep] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            sep.topAnchor.constraint(equalTo: topAnchor), sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            location.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), location.centerYAnchor.constraint(equalTo: centerYAnchor),
            location.trailingAnchor.constraint(lessThanOrEqualTo: counts.leadingAnchor, constant: -12),
            counts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), counts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ w: Worktree?) {
        let m = AppModel.shared
        if m.client == nil { location.stringValue = "Background service offline"; location.textColor = .systemRed }
        else if let w {
            location.textColor = .secondaryLabelColor
            location.stringValue = "\(m.repo(w.repoId)?.name ?? "")  ⎇ \(w.branch)" + (w.prNumber.map { "  ·  PR #\($0)" } ?? "")
            location.toolTip = w.path
        } else { location.stringValue = ""; location.textColor = .secondaryLabelColor }

        counts.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let live = m.sessions.filter { $0.status != .exited && $0.agent != "shell" }
        for (st, label) in [(AgentStatus.waiting, "waiting for you"), (.working, "working"), (.done, "done")] {
            let ss = live.filter { $0.status == st }
            guard !ss.isEmpty else { continue }
            let b = ClosureButton(title: "\(ss.count) \(label)") { (NSApp.delegate as? AppDelegate)?.openSession(ss[0].id) }
            b.isBordered = false; b.font = .systemFont(ofSize: 11, weight: st == .waiting ? .semibold : .regular)
            b.contentTintColor = st == .waiting ? .systemOrange : .secondaryLabelColor
            b.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            b.symbolConfiguration = .init(pointSize: 6, weight: .regular).applying(.init(paletteColors: [StatusDot.color(st)]))
            b.imagePosition = .imageLeading
            b.toolTip = ss.map { "\($0.displayTitle) — \(m.worktree($0.worktreeId)?.branch ?? "")" }.joined(separator: "\n")
            counts.addArrangedSubview(b)
        }
        if live.isEmpty {
            let l = NSTextField(labelWithString: "No agents running"); l.font = .systemFont(ofSize: 11); l.textColor = .tertiaryLabelColor
            counts.addArrangedSubview(l)
        }
    }
}
