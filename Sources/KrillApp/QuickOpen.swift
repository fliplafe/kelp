import AppKit
import Core
import GitKit

/// ⌘P: files, worktrees, agents, commands in one fuzzy list. ⇧⌘P: commands only.
@MainActor
final class QuickOpen: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = QuickOpen()

    struct Item { let kind: String; let icon: String; let title: String; let detail: String; let action: () -> Void }

    private var panel: NSPanel!
    private let field = NSSearchField()
    private let table = NSTableView()
    private var all: [Item] = []
    private var shown: [Item] = []
    private var commandsOnly = false

    func show(commandsOnly: Bool) {
        if panel == nil { build() }
        self.commandsOnly = commandsOnly
        field.placeholderString = commandsOnly ? "Run a command" : "Search files, worktrees, agents and commands"
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
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .fullSizeContentView, .closable], backing: .buffered, defer: false)
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
                guard let a = i.action, !i.isSeparatorItem, !i.title.isEmpty else { continue }
                let key = i.keyEquivalent.isEmpty ? "" : Self.shortcut(i)
                items.append(Item(kind: "Command", icon: "command", title: i.title, detail: [path, key].filter { !$0.isEmpty }.joined(separator: "   "), action: {
                    NSApp.sendAction(a, to: i.target, from: i)
                }))
            }
        }
        if let m = NSApp.mainMenu { walk(m, path: "") }   // extension commands are in the menus (Tools) already
        // Themes, like VS Code's "Color Theme" command.
        for (id, name) in [("auto", "Auto (Light / Dark)")] + ThemeManager.shared.themes.map({ ($0.id, $0.name) }) {
            items.append(Item(kind: "Command", icon: "paintpalette", title: "Color Theme: \(name)", detail: "Settings › Appearance",
                              action: { SettingsStore.shared.set("workbench.theme", .string(id)) }))
        }
        // Every setting, to jump to its page.
        for section in ExtensionRegistry.shared.all.settings {
            for spec in section.specs {
                items.append(Item(kind: "Setting", icon: section.icon, title: "\(section.title): \(spec.title)", detail: spec.description ?? "",
                                  action: { SettingsWindow.show(section: section.id) }))
            }
        }
        if !commandsOnly {
            for w in AppModel.shared.worktrees where !w.archived {
                let repo = AppModel.shared.repo(w.repoId)?.name ?? ""
                items.append(Item(kind: "Workspace", icon: "arrow.triangle.branch", title: w.displayName, detail: "\(repo) · \(w.branch)", action: { Workbench.show(workspace: w.id) }))
            }
            for s in AppModel.shared.sessions where s.status != .exited {
                let wt = AppModel.shared.worktree(s.worktreeId)
                items.append(Item(kind: "Agent", icon: "terminal", title: s.displayTitle, detail: "\(s.status.words) · \(wt?.displayName ?? "")", action: { Workbench.focus(session: s.id) }))
            }
            if let wid = Workbench.shared.workspaceId, let root = AppModel.shared.worktree(wid)?.path {
                Task {
                    let files = (try? await AppModel.shared.client?.call("files.list", .obj(["id": .string(wid)]), as: [String].self)) ?? []
                    all += files.map { f in Item(kind: "File", icon: "doc", title: (f as NSString).lastPathComponent, detail: f, action: { [weak self] in
                        _ = self; Workbench.open(TabURI.file(root + "/" + f))
                    }) }
                    filter()
                }
            }
        }
        all = items
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
        let k = i.keyEquivalent == "\r" ? "↩" : i.keyEquivalent.uppercased()
        return s + k
    }

    @objc private func filterAction() { filter() }
    func controlTextDidChange(_ obj: Notification) { filter() }

    private func filter() {
        let q = field.stringValue
        let pool = commandsOnly ? all.filter { $0.kind == "Command" || $0.kind == "Setting" } : all
        if q.isEmpty {
            shown = Array((commandsOnly ? pool : pool.filter { $0.kind != "File" }).prefix(200))
        } else {
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
        case #selector(NSResponder.insertNewline(_:)): activate(); return true
        case #selector(NSResponder.cancelOperation(_:)): panel.orderOut(nil); return true
        default: return false
        }
    }
    private func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        let r = max(0, min(shown.count - 1, table.selectedRow + d))
        table.selectRowIndexes([r], byExtendingSelection: false); table.scrollRowToVisible(r)
    }
    @objc private func activate() {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard shown.indices.contains(r) else { return }
        panel.orderOut(nil)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        shown[r].action()
    }
    func windowDidResignKey(_ n: Notification) { panel.orderOut(nil) }

    func numberOfRows(in t: NSTableView) -> Int { shown.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let it = shown[row]
        let img = NSImageView(image: NSImage(systemSymbolName: it.icon, accessibilityDescription: it.kind) ?? NSImage())
        img.contentTintColor = .secondaryLabelColor
        let t1 = NSTextField(labelWithString: it.title); t1.font = .systemFont(ofSize: 13, weight: .medium); t1.lineBreakMode = .byTruncatingTail
        let t2 = NSTextField(labelWithString: it.detail); t2.font = .systemFont(ofSize: 11); t2.textColor = .secondaryLabelColor; t2.lineBreakMode = .byTruncatingMiddle
        let kind = NSTextField(labelWithString: it.kind); kind.font = .systemFont(ofSize: 10, weight: .medium); kind.textColor = .tertiaryLabelColor
        let texts = NSStackView(views: [t1, t2]); texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 0
        let row = NSStackView(views: [img, texts, NSView(), kind]); row.spacing = 10; row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        img.widthAnchor.constraint(equalToConstant: 18).isActive = true
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }
}
