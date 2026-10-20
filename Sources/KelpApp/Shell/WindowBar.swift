import AppKit
import Core
import GitKit

/// The window's first row, the title bar: where you are — the workspace, its folder (Open In, Finder, Copy Path), its
/// branch and pull request — and Open Quickly (⌘P) in the middle. The window controller puts the panel toggles in the
/// corners and lines the workspace up with the editor area; the panes' tab strips are the second row.
@MainActor
final class WindowBar: NSView {
    /// The system title bar's height (28 pt before macOS 26, 32 after): the traffic lights sit on its centre line.
    static let height = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height

    /// Icon, name, folder, branch, pull request; hidden without a workspace.
    let context = NSStackView()
    private let icon = NSImageView(), name = NSTextField(labelWithString: "")
    private let folder = WindowBar.chip(nil), branch = WindowBar.chip("arrow.triangle.branch"), pr = WindowBar.chip("arrow.triangle.pull")
    private let search = SearchPill()
    private let awake = NSButton.titlebar("cup.and.saucer", String(localized: "Keep Mac Awake"), tip: "")
    private var info: BranchInfo?

    private var worktree: Worktree? { AppModel.shared.worktree(Workbench.shared.workspaceId) }
    /// The folder the sidebar keeps the pull request for: a desk shares its project's.
    private var badgeFolder: Worktree? { worktree.flatMap { RowBadges.folder(workspace: $0.id) ?? RowBadges.folder(project: $0.repoId) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .ui(13, weight: .semibold); name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(600), for: .horizontal)
        folder.lineBreakMode = .byTruncatingMiddle; folder.setContentCompressionResistancePriority(.init(500), for: .horizontal)
        folder.target = self; folder.action = #selector(folderMenu); folder.toolTip = String(localized: "Open In, Reveal in Finder, Copy Path")
        branch.target = self; branch.action = #selector(branchMenu); branch.toolTip = String(localized: "Switch or create a branch")
        pr.target = self; pr.action = #selector(openPR)
        context.setViews([icon, name, folder, branch, pr], in: .leading)
        context.spacing = 2; context.setCustomSpacing(7, after: icon); context.setCustomSpacing(6, after: name); context.setCustomSpacing(8, after: folder)
        awake.target = self; awake.action = #selector(toggleAwake)
        for v in [context, search, awake] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        // Short of room, the search leaves the centre first, then narrows; only then does the path shorten.
        let wide = search.widthAnchor.constraint(equalToConstant: 280); wide.priority = .init(250)
        let center = search.centerXAnchor.constraint(equalTo: centerXAnchor); center.priority = .init(200)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            context.centerYAnchor.constraint(equalTo: centerYAnchor), search.centerYAnchor.constraint(equalTo: centerYAnchor),
            search.heightAnchor.constraint(equalToConstant: 22), wide, center,
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120), search.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            search.leadingAnchor.constraint(greaterThanOrEqualTo: context.trailingAnchor, constant: 12),
            awake.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 6), awake.centerYAnchor.constraint(equalTo: centerYAnchor),
            awake.widthAnchor.constraint(equalToConstant: 28),   // the three cups differ in width; the search mustn't shift
            awake.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -48)   // clear of the inspector toggle
        ])
        track(owner: self) { WindowBar.awakeMode } changed: { [weak self] in self?.showAwake($0) }
        track(owner: self) { Workbench.shared.workspaceId } changed: { [weak self] _ in
            guard let self else { return }
            self.info = nil; self.reload()
            if let f = self.badgeFolder { RowBadges.shared.refresh(f.id) }
        }
        track(owner: self) { AppModel.shared.worktree(Workbench.shared.workspaceId) } changed: { [weak self] _ in self?.update() }
        track(owner: self) { RowBadges.shared.prs } changed: { [weak self] _ in self?.update() }
        // Source Control saw a change, or Kelp comes back (a branch may have been switched in a terminal meanwhile).
        NotificationCenter.default.addObserver(forName: .kelpGitChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let self, n.object as? String == self.worktree?.id { self.reload() } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    override var wantsUpdateLayer: Bool { true }

    private static func chip(_ symbol: String?) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.bezelStyle = .recessed; b.showsBorderOnlyWhileMouseInside = true
        b.font = .ui(12); b.imagePosition = .imageLeading; b.imageHugsTitle = true
        if let symbol { b.image = Glyph.image(symbol, size: 13) ?? .symbol(symbol, ""); b.symbolConfiguration = .init(pointSize: 11, weight: .regular) }
        return b
    }

    private func reload() {
        guard let w = worktree, let c = AppModel.shared.client else { update(); return }
        Task {
            let i = try? await c.call("git.branches", .obj(["id": .string(w.id)]), as: BranchInfo.self)
            guard w.id == worktree?.id else { return }
            info = i; update()
        }
    }

    private func update() {
        guard let w = worktree else { context.isHidden = true; return }
        context.isHidden = false
        icon.image = AppModel.shared.repo(w.repoId).map { ProjectIcon.image(for: $0.path) }
        name.stringValue = w.displayName
        folder.title = (w.path as NSString).abbreviatingWithTildeInPath
        branch.isHidden = info == nil
        if let info {
            let ahead = info.ahead ?? 0, behind = info.behind ?? 0
            branch.title = (info.current ?? info.head ?? "HEAD") + (ahead + behind > 0 ? "  \(behind)↓ \(ahead)↑" : "")
        }
        let p = badgeFolder.flatMap { RowBadges.pr(RowBadges.shared.prs[$0.id]) }
        pr.isHidden = p == nil
        if let p { pr.attributedTitle = p.0; pr.toolTip = p.1 }
    }

    @objc private func folderMenu() {
        guard let path = worktree?.path else { return }
        let m = NSMenu()
        WorkspaceActions.addOpenIn(to: m, path: path)
        if !m.items.isEmpty { m.addItem(.separator()) }
        m.add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        m.add(String(localized: "Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: folder.bounds.height + 4), in: folder)
    }

    /// The local branches to switch to, and a new one; the rest (remote branches, sync) is in Source Control.
    @objc private func branchMenu() {
        guard let info, let wid = worktree?.id else { return }
        let m = NSMenu()
        for b in info.local { m.add(b) { [weak self] in self?.switchBranch(["branch": .string(b)], wid) }.state = b == info.current ? .on : .off }
        m.addItem(.separator())
        m.add(String(localized: "Create Branch…")) { [weak self] in
            guard let name = prompt(String(localized: "Create Branch"), String(localized: "Starts from \(info.current ?? "HEAD") and switches to it.")), !name.isEmpty else { return }
            self?.switchBranch(["branch": .string(name), "create": true], wid)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: branch.bounds.height + 4), in: branch)
    }

    private func switchBranch(_ params: [String: JSONValue], _ wid: String) {
        var p = params; p["id"] = .string(wid)
        Task {
            if let e = await AppModel.shared.tryCall("git.switch", .object(p)).error { Banner.show(e, style: .error) }
            NotificationCenter.default.post(name: .kelpGitChanged, object: wid)
        }
    }

    /// The setting ("always", "agents", "off"), or "working": agents keep the Mac awake right now (as the daemon counts them).
    private static var awakeMode: String {
        let mode = SettingsStore.shared.string("power.keepAwake") ?? "agents"
        let working = AppModel.shared.sessions.contains { $0.agent != "shell" && $0.status == .working }
        return mode == "agents" && working ? "working" : mode
    }

    /// The cup right of the search, always there so the switch can be found: empty while the Mac may sleep, steaming while
    /// agents keep it awake, orange while it's on for good. A click is Keep Mac Awake (also in the Tools menu); a right-click
    /// picks the mode.
    private func showAwake(_ mode: String) {
        let (symbol, tip) = switch mode {
        case "always": ("cup.and.heat.waves.fill", String(localized: "The Mac stays awake until you click here"))
        case "working": ("cup.and.heat.waves", String(localized: "The Mac stays awake while agents work. Click to keep it awake always"))
        default: ("cup.and.saucer", String(localized: "The Mac can sleep. Click to keep it awake"))
        }
        let cup = NSImage.symbol(symbol, String(localized: "Keep Mac Awake"))   // a recessed button ignores contentTintColor
        awake.image = mode == "always" ? cup.withSymbolConfiguration(.init(paletteColors: [.systemOrange])) : cup
        awake.toolTip = tip
        let m = NSMenu()
        for (v, title) in [("agents", String(localized: "While agents work")), ("always", String(localized: "Always")), ("off", String(localized: "Never"))] {
            m.add(title) { SettingsStore.shared.set("power.keepAwake", .string(v)) }.state = (mode == "working" ? "agents" : mode) == v ? .on : .off
        }
        awake.menu = m
    }

    @objc private func toggleAwake() { ExtensionRegistry.shared.command("power.keepAwake")?.run([:]) }

    @objc private func openPR() {
        guard let w = badgeFolder, let u = RowBadges.shared.prs[w.id]?["url"]?.string else { return }
        Workbench.open(u, workspace: worktree?.id)
    }
}

/// Open Quickly as a place to click: it looks like a search field and opens the ⌘P palette (files, agents, commands).
@MainActor
final class SearchPill: NSControl {
    private let glass = NSImageView(image: .symbol("magnifyingglass", ""))
    private let label = NSTextField(labelWithString: ""), key = NSTextField(labelWithString: "⌘P")
    private let full = String(localized: "Files, agents, commands"), short = String(localized: "Search")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.symbolConfiguration = .init(pointSize: 11, weight: .regular); glass.contentTintColor = .secondaryLabelColor
        label.font = .ui(12); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        key.font = .ui(11); key.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [glass, label, NSView(), key]); row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 10); row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)])
        toolTip = String(localized: "Open Quickly (⌘P)")
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(String(localized: "Open Quickly"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor }
    override var wantsUpdateLayer: Bool { true }
    override func layout() {
        super.layout(); layer?.cornerRadius = bounds.height / 2
        // Short of room, "Search" rather than "Files, a…". The room is the pill's, so the choice doesn't feed back on itself.
        let room = bounds.width - 19 - glass.frame.width - key.frame.width - 18
        let text = (full as NSString).size(withAttributes: [.font: label.font ?? .ui(12)]).width <= room ? full : short
        if label.stringValue != text { label.stringValue = text }
    }
    /// The whole pill takes the click; in the title bar its label would move the window instead.
    override func hitTest(_ p: NSPoint) -> NSView? { super.hitTest(p) == nil ? nil : self }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with e: NSEvent) { QuickOpen.shared.show(commandsOnly: false) }
    override func accessibilityPerformPress() -> Bool { QuickOpen.shared.show(commandsOnly: false); return true }
}
