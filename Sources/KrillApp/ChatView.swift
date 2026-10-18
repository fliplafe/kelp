import AppKit
import WebKit
import Core
import Agents
import Markdown

/// Structured chat with Claude Code in a worktree: Markdown answers, one-line tool calls with results, the agent's plan
/// as a checklist, and the cost of each turn. The conversation lives in the daemon, like terminals do.
@MainActor
final class ChatViewController: NSViewController, NSTextViewDelegate {
    static var open: [String: ChatViewController] = [:]
    private static var subscribed = false
    let chatId: String, worktree: Worktree
    private let web = WKWebView()
    private let input = NSTextView()
    private let status = NSTextField(labelWithString: "Starting Claude…")
    private var html: [String] = []
    private var tools: [String: Int] = [:]   // tool id -> index of its row, to mark results

    /// Asks for model / permissions, starts the chat in the daemon and hands back its id.
    static func start(worktree w: Worktree, then: @escaping (String) -> Void) {
        let form = LaunchForm(withPrompt: false, defaultAgent: "claude")
        form.agent.isEnabled = false; form.effort.isEnabled = false
        let a = NSAlert(); a.messageText = "New Chat"; a.informativeText = "A structured conversation with Claude Code in \(w.branch). Edits are applied directly; in Yolo mode it may also run commands."
        a.accessoryView = form.view; a.addButton(withTitle: "Start"); a.addButton(withTitle: "Cancel")
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            var p = form.params; p["worktreeId"] = .string(w.id)
            guard let r = await AppModel.shared.call("chat.start", .object(p)), let id = r["id"]?.string else { return }
            then(id)
        }
    }

    /// One listener routes daemon chat lines to their views.
    static func subscribe() {
        guard !subscribed else { return }; subscribed = true
        AppModel.shared.onChatLine = { id, line in open[id]?.receive(line) }
    }

    init(chatId: String, worktree: Worktree) {
        self.chatId = chatId; self.worktree = worktree
        super.init(nibName: nil, bundle: nil)
        Self.subscribe(); Self.open[chatId] = self
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        input.isRichText = false; input.font = .systemFont(ofSize: 13); input.delegate = self
        input.isAutomaticQuoteSubstitutionEnabled = false; input.textContainerInset = NSSize(width: 6, height: 6)
        let isv = NSScrollView(); isv.documentView = input; isv.hasVerticalScroller = true; isv.borderType = .bezelBorder
        input.isVerticallyResizable = true; input.autoresizingMask = .width
        let send = NSButton(title: "Send", target: self, action: #selector(sendTapped)); send.bezelStyle = .rounded
        send.keyEquivalent = "\r"; send.keyEquivalentModifierMask = .command
        let stop = NSButton(title: "Stop", target: self, action: #selector(stopTapped)); stop.bezelStyle = .rounded
        let attach = NSButton(image: .symbol("at", "Mention a file"), target: self, action: #selector(attachFile)); attach.bezelStyle = .rounded
        attach.toolTip = "Mention a file (@path)"
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [attach, status, NSView(), stop, send]); buttons.spacing = 8
        let root = NSView()
        for v in [web, isv, buttons] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: root.topAnchor), web.leadingAnchor.constraint(equalTo: root.leadingAnchor), web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            isv.topAnchor.constraint(equalTo: web.bottomAnchor, constant: 8), isv.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            isv.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), isv.heightAnchor.constraint(equalToConstant: 76),
            buttons.topAnchor.constraint(equalTo: isv.bottomAnchor, constant: 8), buttons.leadingAnchor.constraint(equalTo: isv.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: isv.trailingAnchor), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        view = root
        render()
        Task {   // replay what happened before this window existed
            for l in (await AppModel.shared.call("chat.history", .obj(["id": .string(chatId)])))?.array ?? [] { if let s = l.string { receive(s) } }
        }
    }

    func receive(_ line: String) {
        if line.contains(#""type":"krill_exit""#) { status.stringValue = "Claude exited"; return }
        if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], o["type"] as? String == "user",
           let c = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first, c["type"] as? String == "text", let t = c["text"] as? String {
            html.append("<div class='me'>\(Self.esc(t))</div>"); render(); return
        }
        for e in ChatEvent.parse(Data(line.utf8)) {
            switch e {
            case .started(let model, _): status.stringValue = model
            case .text(let t): html.append("<div class='ai'>\(MarkdownHTML.render(t))</div>")
            case .tool(let id, _, let summary): tools[id] = html.count; html.append("<div class='tool'>◌ \(Self.esc(summary))</div>")
            case .toolResult(let id, let ok, let preview):
                if let i = tools[id] {
                    html[i] = html[i].replacingOccurrences(of: "◌", with: ok ? "✓" : "✕")
                    if !ok { html[i] += "<pre class='err'>\(Self.esc(preview))</pre>" }
                }
            case .todos(let todos):
                let items = todos.map { t in "<li class='\(t.state)'>\(t.state == "completed" ? "☑" : t.state == "in_progress" ? "◐" : "☐") \(Self.esc(t.text))</li>" }.joined()
                html.append("<ul class='plan'>\(items)</ul>")
            case .finished(let ok, let cost, let turns):
                let c = cost.map { String(format: "$%.3f", $0) } ?? ""
                html.append("<div class='end'>\(ok ? "Done" : "Stopped") \(c.isEmpty ? "" : "· " + c) \(turns.map { "· \($0) turns" } ?? "")</div>")
                status.stringValue = ok ? "Ready" : "Stopped"
            case .other: break
            }
        }
        render()
    }

    private func render() {
        let empty = html.isEmpty ? "<p class='hint'>Ask Claude to do something in <b>\(Self.esc(worktree.branch))</b>. ⌘↩ sends.</p>" : ""
        let body = empty + html.joined(separator: "\n") + Self.css
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        web.loadHTMLString(MarkdownHTML.page(body: body, baseURL: URL(fileURLWithPath: worktree.path), dark: dark) + "<script>window.scrollTo(0, document.body.scrollHeight)</script>", baseURL: nil)
    }

    @objc private func sendTapped() {
        let t = input.string.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }
        input.string = ""; status.stringValue = "Working…"
        Task { await AppModel.shared.call("chat.send", .obj(["id": .string(chatId), "text": .string(t)])) }
    }
    @objc private func stopTapped() { Task { await AppModel.shared.call("chat.stop", .obj(["id": .string(chatId)])) } }
    @objc private func attachFile() {
        let p = NSOpenPanel(); p.directoryURL = URL(fileURLWithPath: worktree.path); p.allowsMultipleSelection = true
        guard let w = view.window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let self else { return }
            let root = self.worktree.path + "/"
            let refs = p.urls.map { "@" + $0.path.replacingOccurrences(of: root, with: "") }.joined(separator: " ")
            self.input.insertText(refs + " ", replacementRange: self.input.selectedRange())
        }
    }
    func focusInput() { view.window?.makeFirstResponder(input) }

    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    static let css = """
    <style>
    .me { margin: 14px 0 6px auto; max-width: 80%; width: fit-content; padding: 8px 12px; border-radius: 12px; background: rgba(10,132,255,.12); white-space: pre-wrap; }
    .ai { margin: 6px 0; } .tool { font: 12px ui-monospace, monospace; color: #888; margin: 2px 0; }
    .plan { list-style: none; padding: 8px 12px; border-radius: 8px; background: rgba(127,127,127,.08); } .plan .completed { color: #888; text-decoration: line-through; }
    .end { font-size: 11px; color: #888; margin: 8px 0 16px; } .hint { color: #888; } pre.err { color: #e5484d; font-size: 11px; }
    </style>
    """
}
