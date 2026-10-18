import AppKit
import Core
import Agents

/// "New Workspace": task, project, agent, base branch. Creates the branch + checkout and starts the agent on the task,
/// so each piece of work gets its own isolated copy of the repo.
@MainActor
final class WorkspaceComposer: NSObject, NSTextViewDelegate {
    private static var current: WorkspaceComposer?
    private let sheet: NSWindow
    private let task = NSTextView()
    private let placeholder = NSTextField(labelWithString: "What should the agent work on? Leave empty for a blank workspace.")
    private let project = NSPopUpButton()
    private let agent = NSPopUpButton()
    private let makeDefault = NSButton(checkboxWithTitle: "Set as default", target: nil, action: nil)
    private let base = NSPopUpButton()
    private let name = NSTextField()
    private let yolo = NSButton(checkboxWithTitle: "Skip permission prompts", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let create = NSButton(title: "Create Workspace", target: nil, action: nil)
    private let agents = AgentCatalog.installed(AppModel.shared.agents)
    private var busy = false

    static func show(repo: Repo? = nil, task text: String = "") {
        guard current == nil, let win = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        guard let repo = repo ?? AppModel.shared.repos.first else { (NSApp.delegate as? AppDelegate)?.addProject(); return }
        let c = WorkspaceComposer(repo: repo, text: text)
        current = c
        win.beginSheet(c.sheet) { _ in current = nil }
        c.sheet.makeFirstResponder(c.task)
    }

    private init(repo: Repo, text: String) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        sheet.title = "New Workspace"
        let title = NSTextField(labelWithString: "New Workspace"); title.font = .systemFont(ofSize: 17, weight: .semibold)
        let sub = NSTextField(wrappingLabelWithString: "Each workspace is its own branch and checkout, so agents never step on each other's changes.")
        sub.textColor = .secondaryLabelColor; sub.font = .systemFont(ofSize: 12)

        task.isRichText = false; task.font = .systemFont(ofSize: 13); task.textContainerInset = NSSize(width: 6, height: 8)
        task.isAutomaticQuoteSubstitutionEnabled = false; task.isAutomaticDashSubstitutionEnabled = false
        task.allowsUndo = true; task.delegate = self; task.string = text
        task.isVerticallyResizable = true; task.autoresizingMask = .width
        let scroll = NSScrollView(); scroll.documentView = task; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .placeholderTextColor; placeholder.font = .systemFont(ofSize: 13); placeholder.lineBreakMode = .byWordWrapping
        placeholder.maximumNumberOfLines = 2; placeholder.isHidden = !text.isEmpty
        placeholder.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(placeholder)

        for r in AppModel.shared.repos { project.addItem(withTitle: r.name); project.lastItem?.representedObject = r }
        project.selectItem(at: AppModel.shared.repos.firstIndex { $0.id == repo.id } ?? 0)
        project.target = self; project.action = #selector(projectChanged)

        let def = UserDefaults.standard.string(forKey: "defaultAgent") ?? "claude"
        for a in agents {
            agent.addItem(withTitle: a.name); agent.lastItem?.representedObject = a.id
            agent.lastItem?.image = NSImage(systemSymbolName: AgentCatalog.symbol(a.id), accessibilityDescription: nil)
        }
        if !agents.isEmpty { agent.menu?.addItem(.separator()) }
        agent.addItem(withTitle: "Blank Terminal"); agent.lastItem?.representedObject = "shell"
        agent.lastItem?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        agent.selectItem(at: agents.firstIndex { $0.id == def } ?? (agents.isEmpty ? agent.numberOfItems - 1 : 0))
        agent.target = self; agent.action = #selector(agentChanged)

        name.placeholderString = "Named from the task"
        yolo.state = UserDefaults.standard.string(forKey: "permissionMode") == "yolo" ? .on : .off
        yolo.toolTip = "The agent edits files and runs commands without asking. It only touches this workspace's checkout."

        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        let agentRow = NSStackView(views: [agent, makeDefault]); agentRow.spacing = 10
        let grid = NSGridView(views: [
            [label("Project:"), project],
            [label("Agent:"), agentRow],
            [label("Branch from:"), base],
            [label("Name:"), name],
            [NSGridCell.emptyContentView, yolo]
        ])
        grid.column(at: 0).xPlacement = .trailing; grid.rowSpacing = 10; grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        for v in [project, base] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        name.translatesAutoresizingMaskIntoConstraints = false; name.widthAnchor.constraint(equalToConstant: 260).isActive = true

        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 12); status.lineBreakMode = .byTruncatingTail
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped)); cancel.keyEquivalent = "\u{1b}"
        create.target = self; create.action = #selector(createTapped); create.keyEquivalent = "\r"; create.bezelStyle = .push
        let footer = NSStackView(views: [spinner, status, NSView(), cancel, create]); footer.spacing = 8

        let stack = NSStackView(views: [title, sub, scroll, grid, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.setCustomSpacing(4, after: title); stack.setCustomSpacing(18, after: grid)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(); root.wantsLayer = true; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 560),
            scroll.heightAnchor.constraint(equalToConstant: 110), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            sub.widthAnchor.constraint(equalTo: scroll.widthAnchor), footer.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 11), placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 9),
            placeholder.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -11)
        ])
        sheet.contentView = root
        projectChanged(); agentChanged()
    }

    private var repo: Repo? { project.selectedItem?.representedObject as? Repo }
    private var agentId: String { agent.selectedItem?.representedObject as? String ?? "shell" }

    @objc private func projectChanged() {
        guard let r = repo else { return }
        base.removeAllItems(); base.addItem(withTitle: r.baseBranch)
        Task {
            let branches = (await AppModel.shared.call("repo.branches", .obj(["id": .string(r.id)]))?.array ?? []).compactMap(\.string)
            guard repo?.id == r.id else { return }
            for b in branches where b != r.baseBranch { base.addItem(withTitle: b) }
        }
    }

    @objc private func agentChanged() {
        let def = UserDefaults.standard.string(forKey: "defaultAgent") ?? "claude"
        makeDefault.isHidden = agentId == "shell" || agentId == def; makeDefault.state = .off
        let m = agents.first { $0.id == agentId }
        yolo.isEnabled = !(m?.yoloArgs.isEmpty ?? true)
    }

    func textDidChange(_ n: Notification) { placeholder.isHidden = !task.string.isEmpty }

    /// Return creates; Shift/Option-Return adds a line.
    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.isDisjoint(with: [.shift, .option]) ?? true {
            createTapped(); return true
        }
        return false
    }

    @objc private func cancelTapped() { guard !busy else { return }; sheet.sheetParent?.endSheet(sheet) }

    @objc private func createTapped() {
        guard !busy, let r = repo else { return }
        busy = true; create.isEnabled = false; spinner.startAnimation(nil)
        status.textColor = .secondaryLabelColor
        let text = task.string.trimmingCharacters(in: .whitespacesAndNewlines)
        status.stringValue = text.isEmpty || !name.stringValue.isEmpty ? "Creating branch and checkout…" : "Naming the branch on-device…"
        if makeDefault.state == .on { UserDefaults.standard.set(agentId, forKey: "defaultAgent") }
        var p: [String: JSONValue] = ["repoId": .string(r.id), "agent": .string(agentId), "prompt": .string(text),
                                      "name": .string(name.stringValue), "base": .string(base.titleOfSelectedItem ?? r.baseBranch)]
        if yolo.isEnabled, yolo.state == .on { p["mode"] = "yolo" }
        if let pre = UserDefaults.standard.string(forKey: "branchPrefix") { p["branchPrefix"] = .string(pre) }
        Task {
            do {
                guard let c = AppModel.shared.client else { throw RPCError.internalError("Background service isn't running") }
                let res = try await c.call("task.create", .object(p))
                guard let wid = res["worktree"]?["id"]?.string, let s = try? res["session"]?.decode(Session.self) else { throw RPCError.internalError("Unexpected reply") }
                await AppModel.shared.refresh()
                sheet.sheetParent?.endSheet(sheet)
                let d = NSApp.delegate as? AppDelegate
                d?.open(worktree: wid)
                d?.content.workspace?.add(session: s)
            } catch {
                busy = false; create.isEnabled = true; spinner.stopAnimation(nil)
                status.textColor = .systemRed
                status.stringValue = (error as? RPCError)?.message ?? error.localizedDescription
                status.toolTip = status.stringValue
            }
        }
    }
}
