import AppKit
import Core
import GitKit

/// ⌘P: files, worktrees, agents, tabs, commands in one fuzzy list; "#123" finds a pull request. ⇧⌘P: commands only.
/// Empty, it lists the agents to get back to — those that need you first — on ⌘1–⌘6, in an order that holds still
/// while it's open. ⇧↩ opens the choice in a split.
@MainActor
final class QuickOpen: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = QuickOpen()

    struct Item {
        let kind: String; let icon: String; let title: String; let detail: String; let action: () -> Void
        /// ⇧↩: the same thing in a split to the right (files, agents, tabs).
        var split: (() -> Void)?
    }

    private var panel: QuickPanel!
    /// What the empty field shows, made once per opening so rows don't move under the pointer.
    private var recents: [Item] = []
    private var showingRecents = false
    private var prSearch: Task<Void, Never>?
    private let field = NSSearchField()
    private let table = NSTableView()
    private var all: [Item] = []
    private var shown: [Item] = []
    private var commandsOnly = false

    func show(commandsOnly: Bool) {
        if panel == nil { build() }
        self.commandsOnly = commandsOnly
        field.placeholderString = commandsOnly ? String(localized: "Run a command") : String(localized: "Search workspaces, agents, tabs, files and commands — # for pull requests")
        field.stringValue = ""
        collect()
        filter()
        if let w = NSApp.mainWindow {
            let f = w.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 120))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func build() {
        panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .fullSizeContentView, .closable], backing: .buffered, defer: false)
        panel.onNumber = { [weak self] n in self?.pickRecent(n) ?? false }
        panel.title = String(localized: "Open Quickly")   // hidden; the Window menu and VoiceOver read it
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true; panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.hidesOnDeactivate = true; panel.delegate = self; panel.isReleasedWhenClosed = false
        let effect = NSVisualEffectView(); effect.material = .popover; effect.state = .active
        field.font = .systemFont(ofSize: 18); field.focusRingType = .none; field.delegate = self; field.sendsSearchStringImmediately = true
        field.target = self; field.action = #selector(filterAction)
        let col = NSTableColumn(identifier: .init("i")); table.addTableColumn(col); table.headerView = nil
        table.rowHeight = 34; table.dataSource = self; table.delegate = self; table.style = .plain; table.backgroundColor = .clear
        table.target = self; table.doubleAction = #selector(activate)
        let sv = NSScrollView(); sv.documentView = table; sv.hasVerticalScroller = true; sv.drawsBackground = false
        for v in [field, sv] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18), field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            sv.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10), sv.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            sv.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6), sv.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6)
        ])
        panel.contentView = effect
    }

    private func collect() {
        var items: [Item] = []
        // Commands: every enabled menu item with an action.
        func walk(_ m: NSMenu, path: String) {
            for i in m.items {
                if let s = i.submenu { walk(s, path: path.isEmpty ? i.title : path + " › " + i.title); continue }
                guard let a = i.action, !i.isSeparatorItem, !i.isHidden, !i.title.isEmpty else { continue }
                let key = i.keyEquivalent.isEmpty ? "" : Self.shortcut(i)
                items.append(Item(kind: "Command", icon: "command", title: i.title, detail: [path, key].filter { !$0.isEmpty }.joined(separator: "   "), action: {
                    NSApp.sendAction(a, to: i.target, from: i)
                }))
            }
        }
        if let m = NSApp.mainMenu { walk(m, path: "") }   // extension commands are in the menus (Tools) already
        // Themes, like VS Code's "Color Theme" command.
        for (id, name) in [("auto", "Match System")] + ThemeManager.shared.themes.map({ ($0.id, $0.name) }) {
            items.append(Item(kind: "Command", icon: "paintpalette", title: String(localized: "Color Theme: \(name)"), detail: String(localized: "Settings › Appearance"),
                              action: { SettingsStore.shared.set("workbench.theme", .string(id)) }))
        }
        for (id, name) in FileIcon.themes {
            items.append(Item(kind: "Command", icon: "doc.richtext", title: String(localized: "File Icon Theme: \(name)"), detail: String(localized: "Settings › Appearance"),
                              action: { SettingsStore.shared.set("workbench.iconTheme", .string(id)) }))
        }
        // Every setting, to jump to its page.
        for section in ExtensionRegistry.shared.all.settings {
            for spec in section.specs {
                items.append(Item(kind: "Setting", icon: section.icon, title: "\(loc(section.title)): \(loc(spec.title))", detail: loc(spec.description ?? ""),
                                  action: { SettingsWindow.show(section: section.id) }))
            }
        }
        if !commandsOnly {
            collectRecents()
            if let e = Workbench.editor {
                for (uri, title) in e.openTabs where TabURI.scheme(uri) != "session" {
                    items.append(Item(kind: "Tab", icon: "square.on.square", title: title, detail: TabURI.scheme(uri) == "file" ? TabURI.filePath(uri).path : uri,
                                      action: { Workbench.open(uri) }, split: { Workbench.open(uri, split: .right) }))
                }
            }
            for w in AppModel.shared.worktrees where !w.archived {
                let repo = AppModel.shared.repo(w.repoId)?.name ?? ""
                items.append(Item(kind: "Workspace", icon: "arrow.triangle.branch", title: w.displayName, detail: "\(repo) · \(w.branch)", action: { Workbench.show(workspace: w.id) }))
            }
            for s in AppModel.shared.sessions where s.status != .exited {
                let wt = AppModel.shared.worktree(s.worktreeId)
                items.append(Item(kind: "Agent", icon: "terminal", title: AgentCatalog.displayName(s), detail: "\(s.status.words) · \(wt?.displayName ?? "")",
                                  action: { Workbench.focus(session: s.id) }, split: { Workbench.open(TabURI.session(s.id), split: .right, workspace: s.worktreeId) }))
            }
            if let wid = Workbench.shared.workspaceId, let root = AppModel.shared.worktree(wid)?.path {
                Task {
                    let files = (try? await AppModel.shared.client?.call("files.list", .obj(["id": .string(wid)]), as: [String].self)) ?? []
                    all += files.map { f in Item(kind: "File", icon: "doc", title: (f as NSString).lastPathComponent, detail: f,
                                                 action: { Workbench.open(TabURI.file(root + "/" + f)) },
                                                 split: { Workbench.open(TabURI.file(root + "/" + f), split: .right) }) }
                    filter()
                }
            }
        }
        all = items
    }

    /// Agents to get back to: asking or failed first, then finished and unseen, then the latest others; then the
    /// workspaces visited last. The first six get ⌘1–⌘6.
    private func collectRecents() {
        let m = AppModel.shared
        let queue = AttentionQueue.sessions
        let rest = m.sessions.filter { s in s.agent != "shell" && s.status != .exited && !queue.contains { $0.id == s.id } }
            .sorted { ($0.statusAt ?? $0.createdAt) > ($1.statusAt ?? $1.createdAt) }
        var out = (queue + rest).prefix(6).map { s -> Item in
            let w = m.worktree(s.worktreeId)
            return Item(kind: s.status.words, icon: "terminal", title: AgentCatalog.displayName(s), detail: [w?.displayName, m.repo(w?.repoId)?.name].compactMap { $0 }.joined(separator: " · "),
                        action: { Workbench.focus(session: s.id) }, split: { Workbench.open(TabURI.session(s.id), split: .right, workspace: s.worktreeId) })
        }
        let shown = Set(Workbench.shared.visits.reversed())
        for id in Workbench.shared.visits.reversed() where id != Workbench.shared.workspaceId && shown.contains(id) {
            guard let w = m.worktree(id), !out.contains(where: { $0.title == w.displayName && $0.kind == "Workspace" }) else { continue }
            out.append(Item(kind: "Workspace", icon: "arrow.triangle.branch", title: w.displayName, detail: m.repo(w.repoId)?.name ?? "", action: { Workbench.show(workspace: w.id) }))
            if out.count >= 10 { break }
        }
        recents = out
    }

    private func pickRecent(_ n: Int) -> Bool {
        guard showingRecents, recents.indices.contains(n - 1), recents[n - 1].kind != "Workspace" else { return false }
        panel.orderOut(nil); NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        recents[n - 1].action()
        return true
    }

    /// "#123" or "#login": the project's open pull requests (gh), opened in the browser tab.
    private func searchPullRequests(_ q: String) {
        prSearch?.cancel()
        guard let repo = AppModel.shared.worktree(Workbench.shared.workspaceId)?.repoId else { return }
        prSearch = Task { [weak self] in
            let prs = (try? await AppModel.shared.client?.call("github.prs", .obj(["repoId": .string(repo), "filter": "open"])).array) ?? []
            guard let self, !Task.isCancelled, field.stringValue == q else { return }
            let term = String(q.dropFirst()).lowercased()
            shown = prs.filter { p in term.isEmpty || "\(p["number"]?.int ?? 0)".hasPrefix(term) || (p["title"]?.string ?? "").lowercased().contains(term) }.map { p in
                let url = p["url"]?.string ?? ""
                return Item(kind: "Pull Request", icon: "arrow.triangle.pull", title: "#\(p["number"]?.int ?? 0) \(p["title"]?.string ?? "")",
                            detail: [p["author"]?.string, p["headRefName"]?.string].compactMap { $0 }.joined(separator: " · "), action: { Workbench.open(url) })
            }
            table.reloadData()
            if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        }
    }

    /// A title matches when it contains the query, or each query word starts a word of the title.
    static func wordScore(_ title: String, _ query: String) -> Int? {
        let t = title.lowercased(), q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        if t.hasPrefix(q) { return 100 }
        let words = t.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 80 }
        if t.contains(q) { return 60 }
        let parts = q.split(separator: " ").map(String.init)
        return parts.count > 1 && parts.allSatisfy({ p in words.contains { $0.hasPrefix(p) } }) ? 40 : nil
    }

    static func shortcut(_ i: NSMenuItem) -> String {
        var s = ""
        let m = i.keyEquivalentModifierMask
        if m.contains(.control) { s += "⌃" }; if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) || i.keyEquivalent != i.keyEquivalent.lowercased() { s += "⇧" }; if m.contains(.command) { s += "⌘" }
        let k = ["\r": "↩", "\t": "⇥", "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→"][i.keyEquivalent] ?? i.keyEquivalent.uppercased()
        return s + k
    }

    @objc private func filterAction() { filter() }
    func controlTextDidChange(_ obj: Notification) { filter() }

    private func filter() {
        let q = field.stringValue
        let pool = commandsOnly ? all.filter { $0.kind == "Command" || $0.kind == "Setting" } : all
        if !commandsOnly, q.hasPrefix("#") { shown = []; table.reloadData(); searchPullRequests(q); return }
        if q.isEmpty {
            showingRecents = !commandsOnly && !recents.isEmpty
            shown = showingRecents ? recents : Array((commandsOnly ? pool : pool.filter { $0.kind != "File" }).prefix(200))
        } else {
            showingRecents = false
            shown = pool.compactMap { it -> (Item, Int)? in
                // Files: fuzzy paths. Everything else: the words of its title, so "them" finds Color Theme, not random letters.
                if it.kind == "File" { return ProjectFiles.fuzzyScore(it.detail, q).map { (it, $0) } }
                return Self.wordScore(it.title, q).map { (it, $0 + (it.kind == "Command" ? 2 : 0)) }
            }.sorted { $0.1 > $1.1 }.prefix(200).map(\.0)
        }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): choose(split: NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true
        case #selector(NSResponder.cancelOperation(_:)): panel.orderOut(nil); NSApp.mainWindow?.makeKeyAndOrderFront(nil); return true   // back to the terminal
        default: return false
        }
    }
    private func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        let r = max(0, min(shown.count - 1, table.selectedRow + d))
        table.selectRowIndexes([r], byExtendingSelection: false); table.scrollRowToVisible(r)
    }
    @objc private func activate() { choose(split: false) }
    private func choose(split: Bool) {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard shown.indices.contains(r) else { return }
        panel.orderOut(nil)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        if split, let s = shown[r].split { s() } else { shown[r].action() }
    }
    func windowDidResignKey(_ n: Notification) { panel.orderOut(nil) }

    func numberOfRows(in t: NSTableView) -> Int { shown.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let it = shown[row]
        let img = NSImageView(image: it.kind == "File" ? FileIcon.image(it.title) : NSImage(systemSymbolName: it.icon, accessibilityDescription: it.kind) ?? NSImage())
        img.contentTintColor = .secondaryLabelColor
        let t1 = NSTextField(labelWithString: it.title); t1.font = .systemFont(ofSize: 13, weight: .medium); t1.lineBreakMode = .byTruncatingTail
        let t2 = NSTextField(labelWithString: it.detail); t2.font = .systemFont(ofSize: 11); t2.textColor = .secondaryLabelColor; t2.lineBreakMode = .byTruncatingMiddle
        // Empty field: the agents on ⌘1–⌘6 say so.
        let n = showingRecents && row < 6 && it.kind != "Workspace" ? "⌘\(row + 1)  " : ""
        let kind = NSTextField(labelWithString: n + loc(it.kind)); kind.font = .systemFont(ofSize: 10, weight: .medium); kind.textColor = .tertiaryLabelColor
        let texts = NSStackView(views: [t1, t2]); texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 0
        let row = NSStackView(views: [img, texts, NSView(), kind]); row.spacing = 10; row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        img.widthAnchor.constraint(equalToConstant: 18).isActive = true
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }
}

/// The palette's window: ⌘1–⌘6 pick from the agents it lists before the main menu sees them (they select tabs there).
final class QuickPanel: NSPanel {
    var onNumber: ((Int) -> Bool)?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, let n = Int(e.charactersIgnoringModifiers ?? ""),
           (1...6).contains(n), onNumber?(n) == true { return true }
        return super.performKeyEquivalent(with: e)
    }
}
