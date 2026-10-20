import AppKit
import WebKit
import Markdown
import EditorKit

/// A Markdown file: editor, live preview, or both, with a formatting bar for specs and plans you write for agents.
@MainActor
final class MarkdownTab: NSViewController {
    let editor: CodeEditor
    let url: URL
    let path: String
    private let web = WKWebView()
    private let links = PreviewLinks()
    private let mode = NSSegmentedControl(labels: [String(localized: "Edit"), String(localized: "Split"), String(localized: "Preview")], trackingMode: .selectOne, target: nil, action: nil)
    private let split = NSSplitView()
    private var renderTask: Task<Void, Never>?
    /// Documents to read (Kelp's help) open as the preview.
    var startInPreview = false
    private var narrow = false

    init(editor: CodeEditor, url: URL, path: String) {
        self.editor = editor; self.url = url; self.path = path
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        func b(_ sym: String, _ tip: String, _ sel: Selector) -> NSButton {
            let x = NSButton(image: .symbol(sym, tip), target: self, action: sel)
            x.bezelStyle = .texturedRounded; x.toolTip = tip; return x
        }
        mode.selectedSegment = startInPreview ? 2 : 1; mode.target = self; mode.action = #selector(modeChanged)
        let heading = NSPopUpButton(); heading.addItems(withTitles: [String(localized: "Text"), String(localized: "Heading 1"), String(localized: "Heading 2"), String(localized: "Heading 3")]); heading.target = self; heading.action = #selector(headingPicked(_:))
        heading.bezelStyle = .texturedRounded
        let bar = NSStackView(views: [heading, b("bold", String(localized: "Bold (⌘B)"), #selector(bold)), b("italic", String(localized: "Italic (⌘I)"), #selector(italic)),
                                      b("chevron.left.forwardslash.chevron.right", String(localized: "Code"), #selector(code)), b("link", String(localized: "Link (⌘K)"), #selector(link)),
                                      b("list.bullet", String(localized: "Bulleted list"), #selector(bullets)), b("list.number", String(localized: "Numbered list"), #selector(numbered)),
                                      b("checklist", String(localized: "Task list"), #selector(tasks)), b("tablecells", String(localized: "Table"), #selector(table)),
                                      NSView(), mode])
        bar.spacing = 4; bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        split.isVertical = true; split.dividerStyle = .thin
        web.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        web.navigationDelegate = links
        split.addArrangedSubview(editor.view); split.addArrangedSubview(web)
        editor.view.clipsToBounds = true
        view = pinned(bar: bar, body: split)
        applyMode()
        render()
    }

    private var positioned = false
    override func viewDidLayout() {
        super.viewDidLayout()
        if !positioned, split.bounds.width > 700 { positioned = true; split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
        // Split in a narrow pane squeezes the preview to a word per line: show the source until there's room.
        let n = split.bounds.width > 0 && split.bounds.width < 760
        if n != narrow { narrow = n; mode.setToolTip(n ? String(localized: "Split (needs a wider pane)") : nil, forSegment: 1); applyMode() }
    }

    func textChanged() {
        renderTask?.cancel()
        renderTask = Task { try? await Task.sleep(for: .milliseconds(250)); if !Task.isCancelled { render() } }
    }

    private func render() {
        let text = editor.text, dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let html = MarkdownHTML.page(body: MarkdownHTML.render(text), baseURL: url.deletingLastPathComponent(), dark: dark) + (MarkdownHTML.mermaid(for: text, dark: dark) ?? "")
        // Keep the reader's place across re-renders.
        web.evaluateJavaScript("window.scrollY") { [weak self] y, _ in
            guard let self else { return }
            self.web.loadHTMLString(html + "<script>window.scrollTo(0, \((y as? Double) ?? 0))</script>", baseURL: self.url.deletingLastPathComponent())
        }
    }

    @objc private func modeChanged() { applyMode() }

    /// ⇧⌘V: source → split → preview → source (split is skipped while the pane is too narrow for it).
    func cycleMode() {
        var m = (mode.selectedSegment + 1) % 3
        if m == 1, narrow { m = 2 }
        mode.selectedSegment = m; applyMode()
        if m != 2 { editor.focus() }
    }

    private func applyMode() {
        let m = mode.selectedSegment
        editor.view.isHidden = m == 2; web.isHidden = m == 0 || (m == 1 && narrow)
        split.adjustSubviews()
        if m == 1, !narrow { split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
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
        guard let u = prompt(String(localized: "Insert link"), "URL", initial: "https://") else { return }
        edit { MarkdownFormat.makeLink($0, $1, url: u) }
    }
}
