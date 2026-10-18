import AppKit
import Core

/// An empty workspace: say what the agent should do, or open a terminal / browser / anything an extension offers.
@MainActor
final class StartView: NSView, NSTextViewDelegate {
    var onStart: ((String, String) -> Void)?
    var onOpen: ((String) -> Void)?
    private let input = NSTextView()
    private let placeholder = NSTextField(labelWithString: "What should the agent do?")
    private let agent = NSPopUpButton()
    private let agents = AgentCatalog.installed(AgentCatalog.all)
    private let card = NSView()

    init(worktree w: Worktree) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: w.displayName)
        title.font = .systemFont(ofSize: 22, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: "⎇ \(w.branch)")
        sub.font = .systemFont(ofSize: 12); sub.textColor = .secondaryLabelColor; sub.toolTip = w.path

        input.isRichText = false; input.font = .systemFont(ofSize: 14); input.textContainerInset = NSSize(width: 8, height: 10)
        input.isAutomaticQuoteSubstitutionEnabled = false; input.allowsUndo = true; input.delegate = self
        input.drawsBackground = false; input.isVerticallyResizable = true; input.autoresizingMask = .width
        let scroll = NSScrollView(); scroll.documentView = input; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        placeholder.textColor = .placeholderTextColor; placeholder.font = .systemFont(ofSize: 14)
        placeholder.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(placeholder)

        for a in agents {
            agent.addItem(withTitle: a.name); agent.lastItem?.representedObject = a.id
            agent.lastItem?.image = .symbol(AgentCatalog.symbol(a.id))
        }
        agent.selectItem(at: agents.firstIndex { $0.id == AgentCatalog.defaultAgent } ?? 0)
        agent.isBordered = false; agent.controlSize = .small; agent.isHidden = agents.isEmpty
        let startButton = NSButton(title: "Start", target: self, action: #selector(startTapped))
        startButton.bezelStyle = .push; startButton.keyEquivalent = "\r"; startButton.isEnabled = !agents.isEmpty
        let hint = NSTextField(labelWithString: agents.isEmpty ? "No agent CLI found — install Claude Code, Codex or another agent." : "↩ start  ·  ⇧↩ new line")
        hint.font = .systemFont(ofSize: 11); hint.textColor = agents.isEmpty ? .systemOrange : .tertiaryLabelColor
        let bar = NSStackView(views: [agent, hint, NSView(), startButton]); bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 8, right: 8)
        let cardStack = NSStackView(views: [scroll, bar]); cardStack.orientation = .vertical; cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true; card.layer?.cornerRadius = 12; card.layer?.borderWidth = 1; card.addSubview(cardStack)
        card.translatesAutoresizingMaskIntoConstraints = false

        func action(_ t: String, _ sym: String, _ uri: String) -> NSButton {
            let b = ClosureButton(title: t) { [weak self] in self?.onOpen?(uri) }
            b.image = .symbol(sym); b.bezelStyle = .accessoryBarAction; b.imagePosition = .imageLeading
            b.contentTintColor = .secondaryLabelColor; b.font = .systemFont(ofSize: 12)
            return b
        }
        var quick = [action("Terminal", "terminal", "terminal:")]
        let ctx = IDEContext.current
        for e in ExtensionRegistry.shared.all.editors.prefix(4) { if let uri = e.uri(ctx) { quick.append(action(e.title, e.icon, uri)) } }
        let actions = NSStackView(views: quick); actions.spacing = 6

        let stack = NSStackView(views: [title, sub, card, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.setCustomSpacing(18, after: sub); stack.setCustomSpacing(14, after: card)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: 620); width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            width, stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(equalToConstant: 96),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor), cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor), cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 13), placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 10)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true; updateLayer() }

    func focus() { window?.makeFirstResponder(input) }
    func textDidChange(_ n: Notification) { placeholder.isHidden = !input.string.isEmpty }
    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.isDisjoint(with: [.shift, .option]) ?? true {
            startTapped(); return true
        }
        return false
    }
    @objc private func startTapped() {
        guard let id = agent.selectedItem?.representedObject as? String else { return }
        onStart?(id, input.string.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension Worktree {
    /// The name people see: their own, or the branch.
    var displayName: String { note.isEmpty ? branch : note }
}
