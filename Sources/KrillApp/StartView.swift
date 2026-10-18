import AppKit
import Core
import Agents

/// What an empty workspace shows: say what the agent should do, or open a terminal / Changes / Files / Browser.
@MainActor
final class StartView: NSView, NSTextViewDelegate {
    var onStart: ((String, String, [String: JSONValue]) -> Void)?
    var onOpen: ((TabKind) -> Void)?
    var onTerminal: (() -> Void)?
    private let input = NSTextView()
    private let placeholder = NSTextField(labelWithString: "What should the agent do in this workspace?")
    private let agent = NSPopUpButton()
    private let agents = AgentCatalog.installed(AppModel.shared.agents)

    init(worktree w: Worktree) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: w.branch)
        title.font = .systemFont(ofSize: 22, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: (w.note.isEmpty ? "" : w.note + "  ·  ") + "branched from \(w.base.isEmpty ? "main" : w.base)")
        sub.font = .systemFont(ofSize: 12); sub.textColor = .secondaryLabelColor; sub.lineBreakMode = .byTruncatingTail
        sub.toolTip = w.path

        input.isRichText = false; input.font = .systemFont(ofSize: 14); input.textContainerInset = NSSize(width: 8, height: 10)
        input.isAutomaticQuoteSubstitutionEnabled = false; input.allowsUndo = true; input.delegate = self
        input.drawsBackground = false; input.isVerticallyResizable = true; input.autoresizingMask = .width
        let scroll = NSScrollView(); scroll.documentView = input; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        placeholder.textColor = .placeholderTextColor; placeholder.font = .systemFont(ofSize: 14)
        placeholder.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(placeholder)

        let def = UserDefaults.standard.string(forKey: "defaultAgent") ?? "claude"
        for a in agents {
            agent.addItem(withTitle: a.name); agent.lastItem?.representedObject = a.id
            agent.lastItem?.image = NSImage(systemSymbolName: AgentCatalog.symbol(a.id), accessibilityDescription: nil)
        }
        agent.selectItem(at: agents.firstIndex { $0.id == def } ?? 0)
        agent.isBordered = false; agent.controlSize = .small; agent.isHidden = agents.isEmpty
        let start = NSButton(title: "Start", target: self, action: #selector(startTapped))
        start.bezelStyle = .push; start.keyEquivalent = "\r"; start.controlSize = .regular; start.isEnabled = !agents.isEmpty
        let hint = NSTextField(labelWithString: agents.isEmpty ? "No agent CLI found on PATH — install Claude Code, Codex or another agent." : "↩ to start  ·  ⇧↩ new line")
        hint.font = .systemFont(ofSize: 11); hint.textColor = agents.isEmpty ? .systemOrange : .tertiaryLabelColor
        let bar = NSStackView(views: [agent, hint, NSView(), start]); bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 8, right: 8)

        let card = NSStackView(views: [scroll, bar]); card.orientation = .vertical; card.spacing = 0
        card.wantsLayer = true; card.layer?.cornerRadius = 12; card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        self.card = card

        func action(_ t: String, _ sym: String, _ key: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: "\(t)  \(key)", image: NSImage(systemSymbolName: sym, accessibilityDescription: nil)!, target: self, action: sel)
            b.bezelStyle = .accessoryBarAction; b.imagePosition = .imageLeading; b.contentTintColor = .secondaryLabelColor
            b.font = .systemFont(ofSize: 12); return b
        }
        let actions = NSStackView(views: [
            action("Terminal", "terminal", "⌘T", #selector(terminalTapped)),
            action("Changes", "plusminus", "⇧⌘R", #selector(changesTapped)),
            action("Files", "doc.text", "⇧⌘E", #selector(filesTapped)),
            action("Browser", "safari", "⇧⌘B", #selector(browserTapped)),
        ])
        actions.spacing = 6

        let stack = NSStackView(views: [title, sub, card, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.setCustomSpacing(18, after: sub); stack.setCustomSpacing(14, after: card)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.widthAnchor.constraint(equalToConstant: 620), stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(equalToConstant: 96),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 13), placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 10),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -13), sub.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        if let c = stack.constraints.first(where: { $0.firstAttribute == .width && $0.constant == 620 }) { c.priority = .defaultHigh }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    private var card: NSView!

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            card.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }

    func focus() { window?.makeFirstResponder(input) }
    func textDidChange(_ n: Notification) { placeholder.isHidden = !input.string.isEmpty }
    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.intersection([.shift, .option]).isEmpty ?? true {
            startTapped(); return true
        }
        return false
    }

    @objc private func startTapped() {
        guard let id = agent.selectedItem?.representedObject as? String else { return }
        onStart?(id, input.string.trimmingCharacters(in: .whitespacesAndNewlines), [:])
    }
    @objc private func terminalTapped() { onTerminal?() }
    @objc private func changesTapped() { onOpen?(.changes) }
    @objc private func filesTapped() { onOpen?(.files) }
    @objc private func browserTapped() { onOpen?(.browser) }
}
