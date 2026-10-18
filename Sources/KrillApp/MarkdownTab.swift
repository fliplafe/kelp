import AppKit
import WebKit
import Markdown
import EditorKit

/// A Markdown file: editor, live preview, or both, with a formatting bar for specs and plans you write for agents.
@MainActor
final class MarkdownTab: NSViewController, WKScriptMessageHandler {
    let editor: CodeEditor
    let url: URL
    let path: String
    private let web = WKWebView()
    private let mode = NSSegmentedControl(labels: ["Edit", "Split", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
    private let split = NSSplitView()
    private var renderTask: Task<Void, Never>?
    var currentSession: () -> String? = { nil }

    init(editor: CodeEditor, url: URL, path: String) {
        self.editor = editor; self.url = url; self.path = path
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        func b(_ sym: String, _ tip: String, _ sel: Selector) -> NSButton {
            let x = NSButton(image: NSImage(systemSymbolName: sym, accessibilityDescription: tip)!, target: self, action: sel)
            x.bezelStyle = .texturedRounded; x.toolTip = tip; return x
        }
        mode.selectedSegment = 1; mode.target = self; mode.action = #selector(modeChanged)
        let heading = NSPopUpButton(); heading.addItems(withTitles: ["Text", "Heading 1", "Heading 2", "Heading 3"]); heading.target = self; heading.action = #selector(headingPicked(_:))
        heading.bezelStyle = .texturedRounded
        let bar = NSStackView(views: [heading, b("bold", "Bold (⌘B)", #selector(bold)), b("italic", "Italic (⌘I)", #selector(italic)),
                                      b("chevron.left.forwardslash.chevron.right", "Code", #selector(code)), b("link", "Link (⌘K)", #selector(link)),
                                      b("list.bullet", "Bulleted list", #selector(bullets)), b("list.number", "Numbered list", #selector(numbered)),
                                      b("checklist", "Task list", #selector(tasks)), b("tablecells", "Table", #selector(table)),
                                      NSView(), b("text.bubble", "Note to Agent on the preview selection (⇧⌘A)", #selector(noteToAgent)), mode])
        bar.spacing = 4; bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        web.configuration.userContentController.add(WeakHandler(self), name: "krillmd")
        split.isVertical = true; split.dividerStyle = .thin
        web.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        split.addArrangedSubview(editor.view); split.addArrangedSubview(web)
        editor.view.clipsToBounds = true
        view = pinned(bar: bar, body: split)
        render()
    }

    private var positioned = false
    override func viewDidLayout() {
        super.viewDidLayout()
        if !positioned, split.bounds.width > 700 { positioned = true; split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
    }

    func textChanged() {
        renderTask?.cancel()
        renderTask = Task { try? await Task.sleep(for: .milliseconds(250)); if !Task.isCancelled { render() } }
    }

    private func render() {
        let html = MarkdownHTML.page(body: MarkdownHTML.render(editor.text), baseURL: url.deletingLastPathComponent(), dark: view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        // Keep the reader's place across re-renders.
        web.evaluateJavaScript("window.scrollY") { [weak self] y, _ in
            guard let self else { return }
            self.web.loadHTMLString(html + "<script>window.scrollTo(0, \((y as? Double) ?? 0))</script>", baseURL: self.url.deletingLastPathComponent())
        }
    }

    @objc private func modeChanged() {
        editor.view.isHidden = mode.selectedSegment == 2; web.isHidden = mode.selectedSegment == 0
        split.adjustSubviews()
        if mode.selectedSegment == 1 { split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
    }

    private func edit(_ f: (String, NSRange) -> (text: String, selection: NSRange)) {
        let r = f(editor.text, editor.selectedRange); editor.apply(text: r.text, selection: r.selection); editor.focus()
    }
    @objc func bold() { edit(MarkdownFormat.toggleBold) }
    @objc func italic() { edit(MarkdownFormat.toggleItalic) }
    @objc private func code() { edit(MarkdownFormat.toggleCode) }
    @objc private func bullets() { edit(MarkdownFormat.toggleBullet) }
    @objc private func numbered() { edit(MarkdownFormat.toggleNumbered) }
    @objc private func tasks() { edit(MarkdownFormat.toggleTask) }
    @objc private func table() { edit { MarkdownFormat.insertTable($0, $1, columns: 3, rows: 2) } }
    @objc private func headingPicked(_ p: NSPopUpButton) { let l = p.indexOfSelectedItem; edit { MarkdownFormat.heading($0, $1, level: l) }; p.selectItem(at: 0) }
    @objc func link() {
        guard let u = prompt("Insert link", "URL", initial: "https://") else { return }
        edit { MarkdownFormat.makeLink($0, $1, url: u) }
    }

    /// Select text in the preview → a note for the agent quoting it, with the source line.
    @objc func noteToAgent() {
        let js = """
        (() => { const s = window.getSelection(); if (!s || s.isCollapsed) return null;
          let n = s.anchorNode; while (n && !(n.dataset && n.dataset.line)) n = n.parentElement;
          return {text: s.toString(), line: n ? parseInt(n.dataset.line) : 0}; })()
        """
        web.evaluateJavaScript(js) { [weak self] r, _ in
            MainActor.assumeIsolated {
                guard let self, let d = r as? [String: Any], let quote = d["text"] as? String, !quote.isEmpty else { NSSound.beep(); return }
                let line = d["line"] as? Int ?? 0
                guard let note = prompt("Note to agent", "On \(self.path)\(line > 0 ? " line \(line)" : "")"), !note.isEmpty else { return }
                let msg = "Note on \(self.path)\(line > 0 ? ":\(line)" : ""):\n> " + quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n" + note
                guard let sid = self.currentSession() else {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(msg, forType: .string); NSSound.beep(); return
                }
                Task { await AppModel.shared.call("session.send", .obj(["id": .string(sid), "text": .string(msg)])) }
            }
        }
    }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {}
}
