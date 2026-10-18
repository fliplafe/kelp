import AppKit
import Core

/// Every past Claude / Codex conversation on this Mac: search, resume in place, or copy the resume command.
@MainActor
final class HistoryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = HistoryWindow()
    private var window: NSWindow?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let fullText = NSButton(checkboxWithTitle: "Search inside conversations", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var rows: [JSONValue] = []
    private var pending: Task<Void, Never>?

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil); load()
    }

    private func build() {
        for (id, title, w) in [("agent", "Agent", 70.0), ("title", "Conversation", 380), ("cwd", "Folder", 260), ("updated", "Last active", 130)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = w; table.addTableColumn(c)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 22; table.style = .inset; table.usesAlternatingRowBackgroundColors = true
        table.target = self; table.doubleAction = #selector(resume)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let sv = NSScrollView(); sv.documentView = table; sv.hasVerticalScroller = true
        search.placeholderString = "Search titles and folders"; search.delegate = self
        fullText.target = self; fullText.action = #selector(searchChanged)
        let resumeB = NSButton(title: "Resume", target: self, action: #selector(resume)); resumeB.bezelStyle = .rounded; resumeB.keyEquivalent = "\r"
        let copyB = NSButton(title: "Copy Resume Command", target: self, action: #selector(copyCommand)); copyB.bezelStyle = .rounded
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [search, fullText, NSView(), status, copyB, resumeB]); bar.spacing = 8; bar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        search.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Session History"; w.contentView = pinned(bar: bar, body: sv); w.isReleasedWhenClosed = false; w.setFrameAutosaveName("history"); w.center()
        window = w
    }

    func controlTextDidChange(_ obj: Notification) { searchChanged() }
    @objc private func searchChanged() {
        pending?.cancel()
        pending = Task { try? await Task.sleep(for: .milliseconds(250)); if !Task.isCancelled { load() } }
    }

    private func load() {
        status.stringValue = "Loading…"
        Task {
            var p: [String: JSONValue] = ["query": .string(search.stringValue)]
            if fullText.state == .on { p["fullText"] = true }
            rows = (await AppModel.shared.call("history.list", .object(p)))?.array ?? []
            status.stringValue = "\(rows.count) conversations"
            table.reloadData()
        }
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let s: String
        switch c?.identifier.rawValue {
        case "agent": s = r["agent"]?.string == "codex" ? "Codex" : "Claude"
        case "title": s = r["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        case "cwd": s = (r["cwd"]?.string ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~")
        default:
            let d = Date(timeIntervalSinceReferenceDate: r["updated"].flatMap { if case .double(let x) = $0 { x } else { $0.int.map(Double.init) } } ?? 0)
            s = RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
        }
        let l = NSTextField(labelWithString: s); l.lineBreakMode = c?.identifier.rawValue == "cwd" ? .byTruncatingHead : .byTruncatingTail
        if c?.identifier.rawValue == "agent" || c?.identifier.rawValue == "updated" { l.textColor = .secondaryLabelColor }
        return l
    }
    /// Drag a conversation onto a terminal pane: drops its resume command there.
    func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { command(rows[row]) as NSString }

    private func command(_ r: JSONValue) -> String {
        let id = r["id"]?.string ?? ""
        let cwd = (r["cwd"]?.string ?? "").replacingOccurrences(of: "'", with: "'\\''")
        return r["agent"]?.string == "codex" ? "cd '\(cwd)' && codex resume \(id)" : "cd '\(cwd)' && claude --resume \(id)"
    }
    @objc private func copyCommand() {
        guard table.selectedRow >= 0 else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command(rows[table.selectedRow]), forType: .string)
        status.stringValue = "Copied"
    }
    @objc private func resume() {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(r) else { return }
        let d = NSApp.delegate as? AppDelegate
        Task {
            guard let res = await AppModel.shared.call("history.resume", .obj(["session": rows[r]])), let s = try? res.decode(Session.self) else { return }
            AppModel.shared.sessions.append(s)
            _ = d; AppModel.shared.upsert(s); if let w = s.worktreeId { Workbench.show(workspace: w); Workbench.open(TabURI.session(s.id)) }
            else { FloatingTerminal.shared.show(session: s) }
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
