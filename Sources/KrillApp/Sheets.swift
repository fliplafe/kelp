import AppKit
import Core
import Agents

/// Present an alert as a sheet on the main window and await the answer (native, non-blocking).
@MainActor
func runSheet(_ a: NSAlert) async -> NSApplication.ModalResponse {
    guard let w = NSApp.keyWindow ?? NSApp.mainWindow else { return a.runModal() }
    return await withCheckedContinuation { c in a.beginSheetModal(for: w) { c.resume(returning: $0) } }
}

/// Agent + model + effort + permission mode, optionally with a prompt. Used by New Task, New Agent, Hand Off.
@MainActor
final class LaunchForm {
    let agent = NSPopUpButton()
    let model = NSComboBox()
    let effort = NSPopUpButton()
    let account = NSPopUpButton()
    let mode = NSSegmentedControl(labels: ["Ask before actions", "Yolo"], trackingMode: .selectOne, target: nil, action: nil)
    let prompt = NSTextView()
    let view: NSView
    private let agents = AppModel.shared.agents

    init(withPrompt: Bool, promptPlaceholder: String = "", defaultAgent: String? = nil) {
        let def = defaultAgent ?? UserDefaults.standard.string(forKey: "defaultAgent") ?? "claude"
        for a in agents { agent.addItem(withTitle: a.name); agent.lastItem?.representedObject = a.id }
        agent.selectItem(at: agents.firstIndex { $0.id == def } ?? 0)
        effort.addItems(withTitles: ["Default effort", "low", "medium", "high"])
        mode.selectedSegment = UserDefaults.standard.string(forKey: "permissionMode") == "yolo" ? 1 : 0
        model.placeholderString = "Default model"; model.completes = true
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Agent:"), agent],
            [NSTextField(labelWithString: "Account:"), account],
            [NSTextField(labelWithString: "Model:"), model],
            [NSTextField(labelWithString: "Effort:"), effort],
            [NSTextField(labelWithString: "Permissions:"), mode],
        ])
        grid.column(at: 0).xPlacement = .trailing; grid.rowSpacing = 8
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        if withPrompt {
            prompt.isRichText = false; prompt.font = .systemFont(ofSize: 13); prompt.isAutomaticQuoteSubstitutionEnabled = false
            let sv = NSScrollView(); sv.documentView = prompt; sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
            prompt.minSize = NSSize(width: 0, height: 100); prompt.isVerticallyResizable = true; prompt.autoresizingMask = .width
            sv.translatesAutoresizingMaskIntoConstraints = false
            sv.widthAnchor.constraint(equalToConstant: 440).isActive = true; sv.heightAnchor.constraint(equalToConstant: 120).isActive = true
            let hint = NSTextField(labelWithString: promptPlaceholder); hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(sv); stack.addArrangedSubview(hint)
        }
        stack.addArrangedSubview(grid)
        stack.frame = NSRect(x: 0, y: 0, width: 440, height: withPrompt ? 300 : 140)
        view = stack
        agent.target = self; agent.action = #selector(agentChanged); agentChanged()
    }

    @objc private func agentChanged() {
        let m = selected
        model.removeAllItems(); model.addItems(withObjectValues: m.models); model.isEnabled = m.modelFlag != nil
        effort.isEnabled = !m.effortArgs.isEmpty
        mode.setEnabled(!m.yoloArgs.isEmpty, forSegment: 1)
        account.removeAllItems(); account.addItem(withTitle: "Default")
        for p in Accounts.profiles(for: m.id) { account.addItem(withTitle: p.name) }
        account.isEnabled = account.numberOfItems > 1
        if m.yoloArgs.isEmpty { mode.selectedSegment = 0 }
    }

    var selected: AgentManifest { agents[max(0, agent.indexOfSelectedItem)] }

    /// Params for session.create / task.create.
    var params: [String: JSONValue] {
        var p: [String: JSONValue] = ["agent": .string(selected.id), "mode": .string(mode.selectedSegment == 1 ? "yolo" : "manual")]
        if !model.stringValue.isEmpty { p["model"] = .string(model.stringValue) }
        if effort.indexOfSelectedItem > 0 { p["effort"] = .string(effort.titleOfSelectedItem ?? "") }
        if account.indexOfSelectedItem > 0 { p["profile"] = .string(account.titleOfSelectedItem ?? "") }
        return p
    }
}

/// Session-level agent actions shared by panes, menus and the dashboard.
@MainActor
enum AgentActions {
    static var delegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// Prompt → branch named by the local model → worktree → agent working on it.
    static func newTask(repo: Repo) {
        let form = LaunchForm(withPrompt: true, promptPlaceholder: "Describe the task. A branch and worktree are created and the agent starts on it.")
        let a = NSAlert(); a.messageText = "New Task in \(repo.name)"; a.accessoryView = form.view
        a.addButton(withTitle: "Start"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = form.prompt
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            let text = form.prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            var p = form.params; p["repoId"] = .string(repo.id); p["prompt"] = .string(text)
            if let pre = UserDefaults.standard.string(forKey: "branchPrefix") { p["branchPrefix"] = .string(pre) }
            guard let r = await AppModel.shared.call("task.create", .object(p)), let wid = r["worktree"]?["id"]?.string,
                  let s = try? r["session"]?.decode(Session.self) else { return }
            await AppModel.shared.refresh()
            delegate?.open(worktree: wid)
            delegate?.content.workspace?.add(session: s)
        }
    }

    /// New agent in the current worktree with explicit model / effort / permissions.
    static func newAgent(worktree wid: String) {
        let form = LaunchForm(withPrompt: true, promptPlaceholder: "Optional first prompt.")
        let a = NSAlert(); a.messageText = "New Agent"; a.accessoryView = form.view
        a.addButton(withTitle: "Start"); a.addButton(withTitle: "Cancel")
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            var p = form.params; p["worktreeId"] = .string(wid)
            let text = form.prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { p["prompt"] = .string(text) }
            guard let r = await AppModel.shared.call("session.create", .object(p)), let s = try? r.decode(Session.self) else { return }
            delegate?.content.workspace?.add(session: s)
        }
    }

    static func fork(_ sid: String) {
        let form = LaunchForm(withPrompt: true, promptPlaceholder: "What should the fork try? It gets this session's transcript.",
                              defaultAgent: AppModel.shared.session(sid)?.agent)
        let a = NSAlert(); a.messageText = "Fork to a New Workspace"; a.accessoryView = form.view
        a.informativeText = "A new branch starts from this one; a new agent continues from this session's transcript."
        a.addButton(withTitle: "Fork"); a.addButton(withTitle: "Cancel")
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            var p = form.params; p["id"] = .string(sid)
            let text = form.prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { p["prompt"] = .string(text) }
            guard let r = await AppModel.shared.call("session.fork", .object(p)), let s = try? r.decode(Session.self) else { return }
            await AppModel.shared.refresh()
            if let w = s.worktreeId { delegate?.open(worktree: w) }
            delegate?.content.workspace?.add(session: s)
        }
    }

    static func handoff(_ sid: String) {
        let form = LaunchForm(withPrompt: true, promptPlaceholder: "Optional instructions for the next agent.")
        let full = NSButton(checkboxWithTitle: "Include the full transcript (otherwise the recent part)", target: nil, action: nil)
        (form.view as? NSStackView)?.addArrangedSubview(full)
        let a = NSAlert(); a.messageText = "Hand Off to Another Agent"; a.accessoryView = form.view
        a.informativeText = "Continues this task in a fresh session in the same worktree."
        a.addButton(withTitle: "Hand Off"); a.addButton(withTitle: "Cancel")
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            var p = form.params; p["id"] = .string(sid); p["full"] = .bool(full.state == .on)
            let text = form.prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { p["prompt"] = .string(text) }
            guard let r = await AppModel.shared.call("session.handoff", .object(p)), let s = try? r.decode(Session.self) else { return }
            delegate?.content.workspace?.add(session: s, split: true)
        }
    }
}
