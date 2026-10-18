import AppKit
import Core
import LocalAI

/// Commit message sheet: write it, generate it on-device, or hand the commit to the agent.
@MainActor
final class CommitSheet: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
    private let text = NSTextView()
    private let spinner = NSProgressIndicator()
    private let generate = NSButton(title: "Generate", target: nil, action: nil)
    private let worktreeId: String
    private var done: ((String?, Bool) -> Void)?   // (message, askAgent)
    private static var current: CommitSheet?

    init(worktreeId: String) {
        self.worktreeId = worktreeId
        super.init()
        let title = NSTextField(labelWithString: "Commit message"); title.font = .boldSystemFont(ofSize: 13)
        text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.isAutomaticQuoteSubstitutionEnabled = false
        text.isVerticallyResizable = true; text.autoresizingMask = .width
        let sv = NSScrollView(); sv.documentView = text; sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
        generate.target = self; generate.action = #selector(gen); generate.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil); generate.imagePosition = .imageLeading
        generate.toolTip = LocalAI.isAvailable ? "Draft from the staged diff with the on-device model" : "On-device model unavailable; asks the agent instead"
        let ask = NSButton(title: "Ask Agent to Commit", target: self, action: #selector(askAgent))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let commit = NSButton(title: "Commit", target: self, action: #selector(commitTapped)); commit.keyEquivalent = "\r"; commit.keyEquivalentModifierMask = .command
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let buttons = NSStackView(views: [generate, spinner, ask, NSView(), cancel, commit]); buttons.spacing = 8
        let hint = NSTextField(labelWithString: "Commits staged changes, or everything if nothing is staged.  ⌘↩ to commit")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let root = NSView()
        for v in [title, sv, hint, buttons] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            sv.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8), sv.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            sv.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), sv.heightAnchor.constraint(equalToConstant: 140),
            hint.topAnchor.constraint(equalTo: sv.bottomAnchor, constant: 6), hint.leadingAnchor.constraint(equalTo: sv.leadingAnchor),
            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 14), buttons.leadingAnchor.constraint(equalTo: sv.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: sv.trailingAnchor), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        panel.contentView = root
        panel.initialFirstResponder = text
    }

    func present(on window: NSWindow, completion: @escaping (String?, Bool) -> Void) {
        done = completion; Self.current = self
        window.beginSheet(panel)
    }

    private func finish(_ msg: String?, _ agent: Bool) {
        panel.sheetParent?.endSheet(panel); done?(msg, agent); done = nil; Self.current = nil
    }
    @objc private func cancel() { finish(nil, false) }
    @objc private func askAgent() { finish(nil, true) }
    @objc private func commitTapped() {
        let m = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { NSSound.beep(); return }
        finish(m, false)
    }
    @objc private func gen() {
        guard LocalAI.isAvailable else { askAgent(); return }
        spinner.startAnimation(nil); generate.isEnabled = false
        Task {
            var m: String?
            if let c = AppModel.shared.client { m = (try? await c.call("ai.commitMessage", .obj(["id": .string(worktreeId)])))?.string }
            spinner.stopAnimation(nil); generate.isEnabled = true
            if let m { text.string = m } else { NSSound.beep() }
        }
    }
}
