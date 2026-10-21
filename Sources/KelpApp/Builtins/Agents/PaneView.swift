import AppKit
import Core
import TerminalKit
import WorkbenchKit

/// One terminal bound to one daemon session. libghostty renders it when available (attached via `kelp attach`,
/// so the daemon keeps the process); SwiftTerm is the fallback.
@MainActor
final class PaneView: NSView, NSMenuItemValidation {
    let sessionId: String
    private var termView = NSView()
    #if canImport(GhosttyKit)
    private var ghostty: GhosttyTerminalView?
    #endif
    private var swiftTerm: RemoteTerminalView?
    private let ended = NSStackView()
    private var lastActivity = Date()

    var onClose: ((PaneView) -> Void)?
    var onRestart: ((PaneView) -> Void)?

    static var useGhostty: Bool {
        #if canImport(GhosttyKit)
        return UserDefaults.standard.string(forKey: "terminalBackend") != "swiftterm" && GhosttyTerminalView.isAvailable
        #else
        return false
        #endif
    }

    init(session: Session) {
        sessionId = session.id
        super.init(frame: .zero)
        wantsLayer = true
        buildTerminal(session)
        buildEndedOverlay()
        for v in [termView, ended] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            termView.topAnchor.constraint(equalTo: topAnchor), termView.leadingAnchor.constraint(equalTo: leadingAnchor),
            termView.trailingAnchor.constraint(equalTo: trailingAnchor), termView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ended.centerXAnchor.constraint(equalTo: termView.centerXAnchor), ended.centerYAnchor.constraint(equalTo: termView.centerYAnchor)
        ])
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        update(session)
    }
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { if swiftTerm != nil { AppModel.shared.detach(session: sessionId) } }

    private let preview = PathPreview()

    private func buildTerminal(_ s: Session) {
        let id = s.id
        #if canImport(GhosttyKit)
        if Self.useGhostty {
            let kelp = Bundle.main.bundleURL.appendingPathComponent(Bundle.main.bundleIdentifier == nil ? "kelp" : "Contents/MacOS/kelp").path
            let cmd = IDE.shellWord(kelp) + " attach \(id)"
            let g = GhosttyTerminalView(command: cmd, cwd: s.cwd, env: ["KELP_SOCKET": Paths.socket.path, "KELP_HOME": Paths.root.path])
            g.onExit = { [weak self] in self?.sessionEnded() }
            g.onSearch = { [weak self] in self?.searchEvent($0) }
            g.onOpenURL = Self.openLink
            // Paths the agent prints are its folder's: its own worktree once it went into one.
            let cwd = { AppModel.shared.session(id)?.currentDir ?? s.cwd }, wid = s.worktreeId
            g.onOpenPath = { token, flags in TerminalPaths.open(token, cwd: cwd(), flags: flags) }
            g.onHoverWord = { [weak self, weak g] token, rect in
                guard let self, let g else { return }
                self.preview.show(token, rect: rect, in: g, cwd: cwd(), worktree: wid)
            }
            ghostty = g; termView = g
            return
        }
        #endif
        let t = RemoteTerminalView(frame: .zero)
        t.onOpenURL = Self.openLink
        t.onInput = { AppModel.shared.write(session: id, $0) }
        t.onResize = { AppModel.shared.resize(session: id, cols: $0, rows: $1) }
        Task { await AppModel.shared.attach(session: id) { [weak self] in self?.swiftTerm?.feed($0); self?.lastActivity = Date() } }
        swiftTerm = t; termView = t
        applySwiftTermAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(applySwiftTermAppearance), name: UserDefaults.didChangeNotification, object: nil)
    }

    private func buildEndedOverlay() {
        let l = NSTextField(labelWithString: String(localized: "Session ended")); l.font = .systemFont(ofSize: 13, weight: .medium); l.textColor = .secondaryLabelColor
        let b = NSButton(title: String(localized: "Restart"), target: self, action: #selector(restartTapped)); b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil); b.imagePosition = .imageLeading
        let c = NSButton(title: String(localized: "Close"), target: self, action: #selector(closeTapped)); c.bezelStyle = .rounded
        let buttons = NSStackView(views: [b, c]); buttons.spacing = 8
        ended.orientation = .vertical; ended.spacing = 10
        [l, buttons].forEach { ended.addArrangedSubview($0) }
        ended.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        ended.wantsLayer = true; ended.layer?.cornerRadius = 10
        ended.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        ended.isHidden = true
    }

    private func sessionEnded() { ended.isHidden = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ended.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); viewDidChangeEffectiveAppearance() }

    /// A link ⌘-clicked in either terminal: local pages open as a browser tab, the rest in the default browser; ⌥ swaps
    /// the two. Files open as a tab, ⌥ or not. Nothing else opens: a program prints these links (OSC 8 hides the target
    /// behind any text), and an app, a .command file or another app's scheme would run.
    static func openLink(_ url: URL) {
        let option = NSEvent.modifierFlags.contains(.option)
        switch PreviewLinks.target(url) {
        case .web(let s):
            let local = url.host == "localhost" || url.host == "127.0.0.1"
            if local != option { Workbench.open(s, split: .right) } else { NSWorkspace.shared.open(url) }
        case .file(let p): Workbench.open(TabURI.file(p), split: .right)
        case .mail(let m): NSWorkspace.shared.open(m)
        case .refused: PreviewLinks.refuse(url)
        }
    }

    /// SwiftTerm only (Ghostty reads its own config): Settings first, then the Ghostty config, then defaults.
    @objc private func applySwiftTermAppearance() {
        guard let t = swiftTerm else { return }
        let d = UserDefaults.standard
        let g = d.object(forKey: "ghosttyTheme") as? Bool ?? true ? GhosttyConfig.load() : nil
        let size = d.object(forKey: "terminalFontSize") as? Double ?? g?.fontSize ?? 13
        let name = (d.string(forKey: "terminalFont")).flatMap { $0.isEmpty ? nil : $0 } ?? g?.fontFamily
        t.setFont(name: name, size: CGFloat(size))
        func color(_ h: String?) -> NSColor? { h.flatMap(GhosttyConfig.rgb).map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) } }
        if let bg = color(g?.background), let fg = color(g?.foreground) { t.apply(theme: TerminalTheme(background: bg, foreground: fg)) }
    }

    func update(_ s: Session) {
        if s.status == .exited { sessionEnded() } else { ended.isHidden = true }
        if s.status == .done || s.status == .waiting { lastActivity = Date() }
    }

    func focus() {
        #if canImport(GhosttyKit)
        if let g = ghostty { g.focus(); return }
        #endif
        swiftTerm?.focus()
    }

    /// Columns × rows now; the last one seen anywhere sizes the next terminal before it's on screen.
    static var lastGrid: (cols: Int, rows: Int)? = {   // kept across launches: the window usually opens at the same size
        let g = UserDefaults.standard.array(forKey: "terminal.lastGrid") as? [Int] ?? []
        return g.count == 2 ? (g[0], g[1]) : nil
    }() {
        didSet { if let g = lastGrid, g != oldValue ?? (0, 0) { UserDefaults.standard.set([g.cols, g.rows], forKey: "terminal.lastGrid") } }
    }
    var gridSize: (cols: Int, rows: Int)? {
        #if canImport(GhosttyKit)
        if let g = ghostty?.gridSize { Self.lastGrid = g; return g }
        #endif
        return nil
    }

    /// What's on screen (tests, "copy context" fallback).
    var visibleText: String {
        #if canImport(GhosttyKit)
        if let g = ghostty { return g.visibleText }
        #endif
        return swiftTerm?.text ?? ""
    }

    /// Text dropped or dictated into the prompt.
    func insert(_ text: String) {
        #if canImport(GhosttyKit)
        if let g = ghostty { g.insert(text); return }
        #endif
        AppModel.shared.write(session: sessionId, Data(text.utf8))
    }

    /// Right-click where the program in the terminal doesn't take the mouse itself, like Terminal's menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        #if canImport(GhosttyKit)
        guard let g = ghostty else { return nil }
        let m = NSMenu()
        m.addItem(withTitle: String(localized: "Copy"), action: #selector(GhosttyTerminalView.copy(_:)), keyEquivalent: "").target = g
        m.items.last?.isEnabled = g.hasSelection; m.autoenablesItems = false
        m.addItem(withTitle: String(localized: "Paste"), action: #selector(GhosttyTerminalView.paste(_:)), keyEquivalent: "").target = g
        m.addItem(withTitle: String(localized: "Select All"), action: #selector(GhosttyTerminalView.selectAll(_:)), keyEquivalent: "").target = g
        m.addItem(.separator())
        m.add(String(localized: "Find…")) { [weak self] in self?.showFind(nil) }
        m.addItem(.separator())
        m.add(String(localized: "Split Right")) { [weak self] in self?.focus(); Workbench.editor?.splitFocused(.right) }
        m.add(String(localized: "Split Down")) { [weak self] in self?.focus(); Workbench.editor?.splitFocused(.down) }
        return m
        #else
        return nil
        #endif
    }

    // MARK: find (Edit › Find reaches the pane through the responder chain)
    private var findBar: FindBar?

    @objc func performFindPanelAction(_ sender: Any?) {
        #if canImport(GhosttyKit)
        guard let g = ghostty else { return }
        switch NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)) {
        case .next?: g.perform(action: "navigate_search:next")
        case .previous?: g.perform(action: "navigate_search:previous")
        case .setFindString?: g.perform(action: "search_selection")   // Ghostty answers with start_search and the text
        default: showFind(nil)
        }
        #endif
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        #if canImport(GhosttyKit)
        if item.action == #selector(performFindPanelAction(_:)) { return ghostty != nil }
        #endif
        return true
    }

    #if canImport(GhosttyKit)
    private func showFind(_ needle: String?) {
        guard let g = ghostty else { return }
        let bar = findBar ?? {
            let b = FindBar()
            b.onSearch = { g.perform(action: "search:" + $0) }
            b.onStep = { g.perform(action: "navigate_search:" + ($0 ? "next" : "previous")) }
            b.onClose = { [weak self] in g.perform(action: "end_search"); self?.focus() }
            b.translatesAutoresizingMaskIntoConstraints = false; addSubview(b)
            NSLayoutConstraint.activate([b.topAnchor.constraint(equalTo: termView.topAnchor, constant: 8),
                                         b.trailingAnchor.constraint(equalTo: termView.trailingAnchor, constant: -14)])
            findBar = b; return b
        }()
        bar.begin(needle)
    }

    private func searchEvent(_ e: GhosttyTerminalView.SearchEvent) {
        switch e {
        case .started(let needle): showFind(needle)
        case .ended: findBar?.isHidden = true
        case .total(let n): findBar?.total = n
        case .selected(let n): findBar?.selected = n
        }
    }
    #endif

    @objc private func closeTapped() { onClose?(self) }
    @objc private func restartTapped() { onRestart?(self) }

    // MARK: drops: files/images/text into the agent's prompt
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var paths = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.path) ?? []
        if paths.isEmpty, let png = TerminalPaste.savedImage(pb) { paths = [png] }
        if paths.isEmpty, let text = pb.string(forType: .string) { insert(text); return true }
        guard !paths.isEmpty else { return false }
        insert(TerminalPaste.paths(paths))
        focus()
        return true
    }
}

extension NSView {
    func snapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) { cacheDisplay(in: bounds, to: rep); img.addRepresentation(rep) }
        return img
    }
}
