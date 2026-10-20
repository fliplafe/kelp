import AppKit
import Core
import GitKit
import WorkbenchKit

/// ⌘P: files, worktrees, agents, tabs, commands in one fuzzy list; "#123" finds a pull request. ⇧⌘P: commands only.
/// Empty, it lists the agents to get back to — those that need you first — on ⌘1–⌘6, in an order that holds still
/// while it's open. ⇧↩ opens the choice in a split. A setting with choices (Color Theme, File Icon Theme, on/off…) lists them
/// right here, the one in effect ticked; for looks, moving through them tries each on, ↩ keeps it, esc goes back.
@MainActor
final class QuickOpen: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = QuickOpen()

    struct Item {
        let kind: String; let icon: String; let title: String; let detail: String; let action: () -> Void
        /// ⇧↩: the same thing in a split to the right (files, agents, tabs).
        var split: (() -> Void)?
        /// An agent's: its state where the icon goes, as on its tab.
        var session: Session?
        /// A setting with choices: its value now, on the right; choosing it lists the choices here.
        var value: String?
        /// One of those choices: the value it sets, whether it's in effect, and its theme's colors.
        var choice: JSONValue?
        var checked = false
        var image: NSImage?
        /// A file's path, ready for fuzzy matching.
        var fuzzy: ProjectFiles.FuzzyPath?
        /// A command's shortcut, at the end of its title's line as in a menu.
        var key = ""
    }
    /// A setting's choices on screen: the key, the value to go back to, whether moving tries them on, the query to return to.
    private struct Choosing { let key: String; let saved: JSONValue?; let tries: Bool; let query: String }
    private var choosing: Choosing?
    /// A list row: a group's heading ("Files", "Agents"…) while searching, or an item.
    private enum Row { case heading(String), item(Item) }
    private var rows: [Row] = []

    private var panel: QuickPanel!
    /// What the empty field shows, made once per opening so rows don't move under the pointer.
    private var recents: [Item] = []
    private var showingRecents = false
    private var prSearch: Task<Void, Never>?
    private var filesLoad: Task<Void, Never>?
    private let field = NSSearchField()
    private let table = NSTableView()
    private let keys = NSTextField(labelWithString: "")
    private var all: [Item] = []
    private var commandsOnly = false

    func show(commandsOnly: Bool) {
        if panel == nil { build() }
        self.commandsOnly = commandsOnly
        list(query: "")
        if let w = NSApp.mainWindow {
            let f = w.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 120))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// The palette's own list (not a setting's choices), with `query` typed.
    private func list(query: String) {
        stopChoosing()
        field.placeholderString = commandsOnly ? String(localized: "Run a command") : String(localized: "Search workspaces, agents, tabs, files and commands")
        // The keys it knows, under the list (they're not written anywhere else).
        keys.stringValue = String(localized: "↑↓ Select    ↩ Open    ⇧↩ Open in a Split    # Pull Requests")
        field.stringValue = query
        collect()
        filter()
    }

    /// A setting's choices in the list instead, the one in effect ticked and selected. Looks (Appearance) are tried on
    /// as the selection moves, so you see the theme before keeping it.
    private func pick(_ section: SettingsSection, _ spec: SettingSpec) {
        let store = SettingsStore.shared, now = store.value(spec.key)
        choosing = Choosing(key: spec.key, saved: store.values[spec.key], tries: section.id == "appearance", query: field.stringValue)
        all = Self.choices(spec).map { v, name in
            let (note, image) = spec.key == "workbench.theme" ? Self.themeLook(v.string ?? "") : ("", nil)
            return Item(kind: "Choice", icon: v.string == "ghostty" ? "terminal" : "", title: name, detail: note, action: { store.set(spec.key, v) },
                        choice: v, checked: v == now, image: image)
        }
        field.placeholderString = "\(loc(section.title)) › \(loc(spec.title))"
        keys.stringValue = choosing?.tries == true ? String(localized: "↑↓ Try On    ↩ Keep    esc Back") : String(localized: "↑↓ Select    ↩ Choose    esc Back")
        field.stringValue = ""
        filter()
    }

    /// Leaves a setting's choices with the value it had: what was tried on goes away.
    private func stopChoosing() {
        if let c = choosing { SettingsStore.shared.preview(c.key, c.saved) }
        choosing = nil
    }

    /// The selected choice, on screen while it's selected (looks only).
    private func tryOn() {
        guard let c = choosing, c.tries, rows.indices.contains(table.selectedRow), case .item(let it) = rows[table.selectedRow] else { return }
        SettingsStore.shared.preview(c.key, it.choice)
    }

    /// What a setting can be set to: the values and their names.
    static func choices(_ spec: SettingSpec) -> [(JSONValue, String)] {
        switch spec.type {
        case "boolean": return [(.bool(true), String(localized: "On")), (.bool(false), String(localized: "Off"))]
        case "number":
            return (spec.options ?? []).compactMap(Double.init).map { v -> (JSONValue, String) in
                let whole = v == v.rounded()
                return (whole ? .int(Int(v)) : .double(v), SettingRow.label(spec.key, whole ? String(Int(v)) : String(v)))
            }
        default: return SettingRow.options(spec).map { (.string($0), SettingRow.label(spec.key, $0)) }
        }
    }

    /// A color theme's row: light or dark, and a tile of its colors (Match System shows both of its themes).
    static func themeLook(_ id: String) -> (String, NSImage?) {
        let themes = ThemeManager.shared.themes
        switch id {
        case "auto": return (String(localized: "Kelp Light or Dark, as macOS is"), swatch(themes.filter { $0.id == "kelp.light" || $0.id == "kelp.dark" }))
        case "ghostty": return (String(localized: "The terminal keeps your Ghostty colors"), nil)
        default:
            guard let t = themes.first(where: { $0.id == id }) else { return ("", nil) }
            return (t.appearance == "light" ? String(localized: "Light") : String(localized: "Dark"), swatch([t]))
        }
    }

    /// Themes side by side in an 18 pt tile: each its background with two lines of "text" in its foreground and blue.
    static func swatch(_ themes: [Theme]) -> NSImage {
        func color(_ hex: String?) -> NSColor { hex.flatMap(GhosttyConfig.rgb).map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) } ?? .gray }
        return NSImage(size: NSSize(width: 18, height: 18), flipped: true) { r in
            let tile = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSGraphicsContext.saveGraphicsState(); tile.addClip()
            let w = r.width / CGFloat(max(themes.count, 1))
            for (i, t) in themes.enumerated() {
                let x = CGFloat(i) * w, c = t.terminal
                color(c?.background).setFill(); NSRect(x: x, y: 0, width: w, height: r.height).fill()
                color(c?.foreground).setFill(); NSRect(x: x + 3, y: 5, width: (w - 6) * 0.9, height: 2).fill()
                color(c?.palette?.dropFirst(4).first).setFill(); NSRect(x: x + 3, y: 10, width: (w - 6) * 0.6, height: 2).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke(); tile.stroke()
            return true
        }
    }

    private func build() {
        panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled, .fullSizeContentView, .closable], backing: .buffered, defer: false)
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
        keys.font = .systemFont(ofSize: 11); keys.textColor = .secondaryLabelColor
        let line = NSBox(); line.boxType = .separator
        for v in [field, sv, line, keys] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18), field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            sv.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10), sv.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            sv.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6), sv.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -4),
            line.leadingAnchor.constraint(equalTo: effect.leadingAnchor), line.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -28),
            keys.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16), keys.centerYAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14)
        ])
        panel.contentView = effect
    }

    private func collect() {
        var items: [Item] = []
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
                items.append(Item(kind: "Agent", icon: "terminal", title: AgentCatalog.displayName(s), detail: "\(s.status.words) · \(shortAgo(s.statusAt ?? s.createdAt)) · \(wt?.displayName ?? "")",
                                  action: { Workbench.focus(session: s.id) }, split: { Workbench.open(TabURI.session(s.id), split: .right, workspace: s.worktreeId) },
                                  session: s))
            }
            filesLoad?.cancel()
            if let wid = Workbench.shared.workspaceId, let root = AppModel.shared.worktree(wid)?.path {
                filesLoad = Task {
                    let files = (try? await AppModel.shared.client?.call("files.list", .obj(["id": .string(wid)]), as: [String].self)) ?? []
                    let fuzzy = await Task.detached { files.map(ProjectFiles.FuzzyPath.init) }.value
                    // Listed again meanwhile (its own load adds them), or a setting's choices are on screen.
                    guard !Task.isCancelled, choosing == nil else { return }
                    all += zip(files, fuzzy).map { f, z in Item(kind: "File", icon: "doc", title: (f as NSString).lastPathComponent, detail: f,
                                                               action: { Workbench.open(TabURI.file(root + "/" + f)) },
                                                               split: { Workbench.open(TabURI.file(root + "/" + f), split: .right) }, fuzzy: z) }
                    filter()
                }
            }
        }
        // After what's open: the empty field without agents to list starts with tabs and workspaces, not the Kelp menu.
        // Commands: every enabled menu item with an action.
        func walk(_ m: NSMenu, path: String) {
            for i in m.items {
                if let s = i.submenu { walk(s, path: path.isEmpty ? i.title : path + " › " + i.title); continue }
                guard let a = i.action, !i.isSeparatorItem, !i.isHidden, !i.title.isEmpty else { continue }
                // Only what the menu would offer now: someone handles it and it's enabled (Run File needs a file…).
                guard let t = NSApp.target(forAction: a, to: i.target, from: i), (t as? NSMenuItemValidation)?.validateMenuItem(i) ?? true else { continue }
                // No icon unless the menu item has one: the same ⌘ on every row said nothing.
                items.append(Item(kind: "Command", icon: "", title: i.title, detail: path, action: { NSApp.sendAction(a, to: i.target, from: i) },
                                  image: i.image, key: i.keyEquivalent.isEmpty ? "" : Self.shortcut(i)))
            }
        }
        if let m = NSApp.mainMenu { walk(m, path: "") }   // extension commands are in the menus (Tools) already
        // Every setting: one with choices (Color Theme…) lists them here, the others open their page.
        for section in ExtensionRegistry.shared.all.settings {
            for spec in section.specs {
                let title = "\(loc(section.title)): \(loc(spec.title))", choices = Self.choices(spec)
                guard !choices.isEmpty else {
                    items.append(Item(kind: "Setting", icon: section.icon, title: title, detail: loc(spec.description ?? ""), action: { SettingsWindow.show(section: section.id) }))
                    continue
                }
                let now = SettingsStore.shared.value(spec.key)
                items.append(Item(kind: "Setting", icon: section.icon, title: title, detail: loc(spec.description ?? ""), action: { [weak self] in self?.pick(section, spec) },
                                  value: choices.first { $0.0 == now }?.1 ?? ""))
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
                        action: { Workbench.focus(session: s.id) }, split: { Workbench.open(TabURI.session(s.id), split: .right, workspace: s.worktreeId) },
                        session: s)
        }
        var seen: Set<String> = []   // each workspace once, at its last visit
        for id in Workbench.shared.visits.reversed() where id != Workbench.shared.workspaceId && seen.insert(id).inserted {
            guard let w = m.worktree(id) else { continue }
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
            setRows(prs.filter { p in term.isEmpty || "\(p["number"]?.int ?? 0)".hasPrefix(term) || (p["title"]?.string ?? "").lowercased().contains(term) }.map { p in
                let url = p["url"]?.string ?? ""
                return Item(kind: "Pull Request", icon: "arrow.triangle.pull", title: "#\(p["number"]?.int ?? 0) \(p["title"]?.string ?? "")",
                            detail: [p["author"]?.string, p["headRefName"]?.string].compactMap { $0 }.joined(separator: " · "), action: { Workbench.open(url) })
            }, grouped: false)
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
        let pool = commandsOnly && choosing == nil ? all.filter { $0.kind == "Command" || $0.kind == "Setting" } : all
        if !commandsOnly, choosing == nil, q.hasPrefix("#") { setRows([], grouped: false); searchPullRequests(q); return }
        if q.isEmpty {
            showingRecents = !commandsOnly && choosing == nil && !recents.isEmpty
            setRows(showingRecents ? recents : Array((commandsOnly ? pool : pool.filter { $0.kind != "File" }).prefix(200)),
                    grouped: !showingRecents && !commandsOnly && choosing == nil)
        } else {
            showingRecents = false
            let fq = ProjectFiles.fuzzyQuery(q)
            setRows(pool.compactMap { it -> (Item, Int)? in
                // Files: fuzzy paths. Everything else: the words of its title, so "them" finds Color Theme, not random letters.
                if let f = it.fuzzy { return ProjectFiles.fuzzyScore(f, fq).map { (it, $0) } }
                return Self.wordScore(it.title, q).map { (it, $0 + (it.kind == "Command" ? 2 : 0)) }
            }.sorted { $0.1 > $1.1 }.prefix(200).map(\.0), grouped: !commandsOnly && choosing == nil)
        }
    }

    /// Searching, the results come in groups under a heading, the group with the best match first.
    private func setRows(_ items: [Item], grouped: Bool) {
        if grouped {
            var order: [String] = [], byGroup: [String: [Item]] = [:]
            for it in items {
                let g = Self.group(it.kind)
                if byGroup[g] == nil { order.append(g) }
                byGroup[g, default: []].append(it)
            }
            rows = order.flatMap { g in [Row.heading(g)] + (byGroup[g] ?? []).map(Row.item) }
        } else {
            rows = items.map(Row.item)
        }
        table.reloadData()
        if let first = rows.firstIndex(where: { if case .item = $0 { true } else { false } }) {
            // A setting's choices open on the one in effect.
            let ticked = field.stringValue.isEmpty ? rows.firstIndex { if case .item(let it) = $0 { it.checked } else { false } } : nil
            table.selectRowIndexes([ticked ?? first], byExtendingSelection: false); table.scrollRowToVisible(ticked ?? 0)
        }
        tryOn()   // the same row index can hold another choice now, so no selection-change call comes
    }
    func tableViewSelectionDidChange(_ n: Notification) { tryOn() }

    private static func group(_ kind: String) -> String {
        ["File": "Files", "Agent": "Agents", "Command": "Commands", "Setting": "Settings", "Workspace": "Workspaces", "Tab": "Tabs"][kind] ?? kind
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): choose(split: NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if let c = choosing { list(query: c.query); return true }   // a setting's choices: back to the list, the old value back
            panel.orderOut(nil); NSApp.mainWindow?.makeKeyAndOrderFront(nil); return true   // back to the terminal
        default: return false
        }
    }
    /// Up and down skip the groups' headings.
    private func move(_ d: Int) {
        var r = table.selectedRow + d
        while rows.indices.contains(r), case .heading = rows[r] { r += d }
        guard rows.indices.contains(r) else { return }
        table.selectRowIndexes([r], byExtendingSelection: false); table.scrollRowToVisible(r)
    }
    @objc private func activate() { choose(split: false) }
    private func choose(split: Bool) {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(r), case .item(let it) = rows[r] else { return }
        if it.value != nil { it.action(); return }   // a setting with choices lists them; the palette stays
        choosing = nil   // the choice is kept: closing mustn't put the old value back
        panel.orderOut(nil)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        if split, let s = it.split { s() } else { it.action() }
    }
    func windowDidResignKey(_ n: Notification) { stopChoosing(); panel.orderOut(nil) }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool { if case .item = rows[row] { true } else { false } }
    func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat { if case .item = rows[row] { 36 } else { 24 } }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        guard case .item(let it) = rows[row] else {
            guard case .heading(let g) = rows[row] else { return nil }
            let h = NSTextField(labelWithString: loc(g)); h.font = .systemFont(ofSize: 11, weight: .semibold); h.textColor = .secondaryLabelColor
            let v = NSStackView(views: [h]); v.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 0, right: 10)
            return v
        }
        let img = NSImageView(image: it.image ?? (it.kind == "File" ? FileIcon.image(it.title) : NSImage(systemSymbolName: it.icon, accessibilityDescription: it.kind) ?? NSImage()))
        img.contentTintColor = .secondaryLabelColor
        // An agent: its state while there's something to see (as on its tab), else its own icon.
        let lead: NSView
        if let s = it.session, [.working, .waiting, .error].contains(s.status) || (s.status == .done && s.unread) {
            let m = StatusMark(size: 14); m.status = s.status; m.unread = s.unread
            let box = NSView(); m.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(m)
            NSLayoutConstraint.activate([m.centerXAnchor.constraint(equalTo: box.centerXAnchor), m.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                                         box.heightAnchor.constraint(equalToConstant: 18)])
            lead = box
        } else {
            if let s = it.session, let i = AgentCatalog.icon(s.agent, size: 18) { img.image = i }
            lead = img
        }
        let t1 = NSTextField(labelWithString: ""); t1.attributedStringValue = Self.highlighted(it.title, field.stringValue); t1.lineBreakMode = .byTruncatingTail
        let t2 = NSTextField(labelWithString: it.detail); t2.font = .systemFont(ofSize: 11); t2.textColor = .secondaryLabelColor; t2.lineBreakMode = it.kind == "Setting" ? .byTruncatingTail : .byTruncatingMiddle   // paths keep both ends, prose its start
        t2.isHidden = it.detail.isEmpty
        // Empty field: the agents on ⌘1–⌘6 say so.
        let n = showingRecents && row < 6 && it.kind != "Workspace" ? "⌘\(row + 1)  " : ""
        let kind = NSTextField(labelWithString: n + (showingRecents ? loc(it.kind) : it.value.map { $0 + "  ›" } ?? "")); kind.font = .systemFont(ofSize: 11)
        kind.textColor = .secondaryLabelColor
        // The choice in effect: a tick at the end, as in a menu.
        let tick = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: String(localized: "Current")) ?? NSImage())
        tick.contentTintColor = .controlAccentColor; tick.isHidden = !it.checked
        // A command's shortcut: at the end of the title's line, as in a menu.
        let key = NSTextField(labelWithString: it.key); key.font = .systemFont(ofSize: 12); key.textColor = .secondaryLabelColor; key.isHidden = it.key.isEmpty
        key.setContentCompressionResistancePriority(.required, for: .horizontal); key.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [t1, key]); top.spacing = 10; top.distribution = .fill
        let texts = NSStackView(views: [top, t2]); texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 0
        top.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        let line = NSStackView(views: [lead, texts, kind, tick]); line.spacing = 10; line.distribution = .fill
        line.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        lead.widthAnchor.constraint(equalToConstant: 18).isActive = true
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        texts.setHuggingPriority(.init(1), for: .horizontal)   // takes the row's width, so the shortcut sits at its end
        for v in [kind, tick] { v.setContentHuggingPriority(.required, for: .horizontal) }
        return line
    }

    /// The title with what was typed in bold: each word of the query where it first occurs.
    static func highlighted(_ title: String, _ query: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        for word in query.split(separator: " ") where !word.isEmpty {
            let r = (title as NSString).range(of: String(word), options: .caseInsensitive)
            if r.location != NSNotFound { s.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .bold), range: r) }
        }
        return s
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
