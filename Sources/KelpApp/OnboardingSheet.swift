import AppKit
import Core

/// The first launch, in one sheet: the agents found on this Mac and which one New Agent starts, a test notification
/// (so a silent banner setting shows up now, not when an agent is waiting), and Add Project.
@MainActor
final class OnboardingSheet: NSWindowController {
    private static var shown: OnboardingSheet?
    private let agents = NSStackView()
    private let pick = NSPopUpButton()
    private let notifyStatus = NSTextField(labelWithString: "")

    /// Once, when there's no project yet.
    static func showIfFirstLaunch() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "onboarding.done"), AppModel.shared.repos.allSatisfy({ $0.path.hasPrefix(Paths.root.path) }) else { return }
        show()
    }

    static func show() {
        guard shown == nil, let w = Workbench.window?.window ?? NSApp.mainWindow else { return }
        let s = OnboardingSheet(window: NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 10), styleMask: [.titled], backing: .buffered, defer: true))
        guard let sheet = s.window else { return }
        s.build(); shown = s
        w.beginSheet(sheet) { _ in shown = nil; UserDefaults.standard.set(true, forKey: "onboarding.done") }
    }

    private func build() {
        let icon = NSImageView(image: NSApp.applicationIconImage); icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let title = NSTextField(labelWithString: String(localized: "Welcome to Kelp")); title.font = .boldSystemFont(ofSize: 17)
        let sub = NSTextField(wrappingLabelWithString: String(localized: "Agents work in their own workspaces here, with the terminal, editor and git next to them."))
        sub.textColor = .secondaryLabelColor; sub.preferredMaxLayoutWidth = 340
        let head = NSStackView(views: [icon, NSStackView(views: [title, sub])]); head.alignment = .top; head.spacing = 14
        (head.arrangedSubviews[1] as? NSStackView).map { $0.orientation = .vertical; $0.alignment = .leading; $0.spacing = 4 }

        agents.orientation = .vertical; agents.alignment = .leading; agents.spacing = 6
        pick.target = self; pick.action = #selector(picked)
        let pickRow = NSStackView(views: [NSTextField(labelWithString: String(localized: "New Agent (⌥⌘T) starts:")), pick]); pickRow.spacing = 8

        let test = ClosureButton(title: String(localized: "Send Test Notification")) { [weak self] in self?.testNotification() }
        test.bezelStyle = .push
        notifyStatus.textColor = .secondaryLabelColor; notifyStatus.font = .systemFont(ofSize: 11)
        let notifyRow = NSStackView(views: [test, notifyStatus]); notifyRow.spacing = 8

        let later = ClosureButton(title: String(localized: "Later")) { [weak self] in self?.close() }; later.bezelStyle = .push; later.keyEquivalent = "\u{1b}"
        let add = ClosureButton(title: String(localized: "Add Project…")) { [weak self] in self?.close(); DispatchQueue.main.async { Workbench.addProject() } }
        add.bezelStyle = .push; add.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), later, add]); buttons.spacing = 8

        let stack = NSStackView(views: [head, section(String(localized: "Agents on this Mac")), agents, pickRow, section(String(localized: "Notifications")), notifyRow, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.setCustomSpacing(18, after: head); stack.setCustomSpacing(18, after: pickRow); stack.setCustomSpacing(22, after: notifyRow)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 20, right: 22)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        window?.contentView = stack
        track(owner: self) { AgentAvailability.shared.ids } changed: { [weak self] _ in self?.fillAgents() }
    }

    private func section(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t); l.font = .systemFont(ofSize: 12, weight: .semibold); return l
    }

    private func fillAgents() {
        agents.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let found = AgentCatalog.installed(AgentCatalog.all)
        let cells: [NSView] = found.map { a in
            let row = NSStackView(views: [NSImageView(image: AgentCatalog.icon(a.id) ?? NSImage()), NSTextField(labelWithString: a.name)]); row.spacing = 6
            return row
        }
        if !cells.isEmpty {   // two columns, like the start page
            let half = (cells.count + 1) / 2
            let grid = NSGridView(views: (0..<half).map { i in [cells[i], i + half < cells.count ? cells[i + half] : NSGridCell.emptyContentView] })
            grid.rowSpacing = 6; grid.columnSpacing = 24; grid.column(at: 0).width = 190
            grid.setContentHuggingPriority(.required, for: .vertical)   // else one row takes the slack
            agents.addArrangedSubview(grid)
        }
        if found.isEmpty {
            let none = NSTextField(wrappingLabelWithString: String(localized: "None found yet. Kelp runs agent CLIs such as Claude Code, Codex or Gemini: install one in Terminal, ")
                                   + String(localized: "or from Settings › Agents, and it shows up here."))
            none.textColor = .secondaryLabelColor; none.preferredMaxLayoutWidth = 410
            agents.addArrangedSubview(none)
        }
        pick.removeAllItems()
        for a in found { pick.addItem(withTitle: a.name); pick.lastItem?.representedObject = a.id; pick.lastItem?.image = AgentCatalog.icon(a.id) }
        pick.isEnabled = !found.isEmpty
        if let i = found.firstIndex(where: { $0.id == AgentCatalog.defaultAgent }) { pick.selectItem(at: i) }
    }

    @objc private func picked() {
        if let id = pick.selectedItem?.representedObject as? String { SettingsStore.shared.set("agents.default", .string(id)) }
    }

    private func testNotification() {
        (NSApp.delegate as? AppDelegate)?.notifier.sendTest { [weak self] ok in
            self?.notifyStatus.stringValue = ok ? String(localized: "Sent. If no banner appeared, check Focus.") : String(localized: "Turned off for Kelp in System Settings › Notifications.")
            self?.notifyStatus.textColor = ok ? .secondaryLabelColor : .systemRed
        }
    }

    override func close() { if let w = window { w.sheetParent?.endSheet(w) } }
}
