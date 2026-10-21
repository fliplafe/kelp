import AppKit
import Core
import TerminalKit
import WorkbenchKit

/// One terminal bound to one daemon session, rendered by libghostty (attached via `kelp attach`, so the daemon keeps
/// the process).
@MainActor
final class PaneView: NSView {
    let sessionId: String
    private var ghostty: GhosttyTerminalView
    private let ended = NSStackView()
    /// `kelp attach` still streams, and from which daemon (`AppModel.connections` when it started).
    private var attached = true
    private var attachedTo = AppModel.shared.connections

    var onClose: ((PaneView) -> Void)?
    var onRestart: ((PaneView) -> Void)?

    init(session: Session) {
        sessionId = session.id
        ghostty = Self.terminal(session)
        super.init(frame: .zero)
        wantsLayer = true
        buildTerminal(session)
        buildEndedOverlay()
        ended.translatesAutoresizingMaskIntoConstraints = false; addSubview(ended)
        NSLayoutConstraint.activate([ended.centerXAnchor.constraint(equalTo: centerXAnchor), ended.centerYAnchor.constraint(equalTo: centerYAnchor)])
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        update(session)
        track(owner: self) { AppModel.shared.connections } changed: { [weak self] _ in self?.settle() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private let preview = PathPreview()

    private static func terminal(_ s: Session) -> GhosttyTerminalView {
        let kelp = Bundle.main.bundleURL.appendingPathComponent(Bundle.main.bundleIdentifier == nil ? "kelp" : "Contents/MacOS/kelp").path
        return GhosttyTerminalView(command: IDE.shellWord(kelp) + " attach \(s.id)", cwd: s.cwd,
                                   env: ["KELP_SOCKET": Paths.socket.path, "KELP_HOME": Paths.root.path])
    }

    private func buildTerminal(_ s: Session) {
        let id = s.id, g = ghostty
        g.translatesAutoresizingMaskIntoConstraints = false
        addSubview(g, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([g.topAnchor.constraint(equalTo: topAnchor), g.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     g.trailingAnchor.constraint(equalTo: trailingAnchor), g.bottomAnchor.constraint(equalTo: bottomAnchor)])
        g.onExit = { [weak self] in self?.attached = false; self?.settle() }
        g.onSearch = { [weak self] in self?.searchEvent($0) }
        g.onOpenURL = Self.openLink
        g.onPasteRefused = { Banner.show(String(localized: "Not pasted: a program put these lines on the clipboard, and this terminal would run them as typed. Copy them yourself to paste here.")) }
        // Paths the agent prints are its folder's: its own worktree once it went into one.
        let cwd = { AppModel.shared.session(id)?.currentDir ?? s.cwd }, wid = s.worktreeId
        g.onOpenPath = { token, flags in TerminalPaths.open(token, cwd: cwd(), flags: flags) }
        g.onHoverWord = { [weak self, weak g] token, rect in
            guard let self, let g else { return }
            self.preview.show(token, rect: rect, in: g, cwd: cwd(), worktree: wid)
        }
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

    /// A new connection may be a new daemon (an update, Restart Background Service, a crash), whose session this stream
    /// no longer reaches — libghostty reports the attach's exit only after a key press, so the connection is the sign.
    /// The session living on, attach again: only on screen, a hidden tab attaches when shown (a restart mustn't wake
    /// every paused agent). Against the same daemon that's one history replay, nothing lost. Ended: "Session ended".
    private func settle() {
        let s = AppModel.shared.session(sessionId), m = AppModel.shared
        if let s, s.status != .exited, m.connected, m.connections != attachedTo, window != nil { reattach(s) }
        ended.isHidden = attached && s?.status != .exited
    }

    private func reattach(_ s: Session) {
        let focused = window?.firstResponder === ghostty
        findBar?.removeFromSuperview(); findBar = nil   // it searched the old terminal
        ghostty.removeFromSuperview()
        ghostty = Self.terminal(s)
        attached = true; attachedTo = AppModel.shared.connections
        buildTerminal(s)
        if focused { focus() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ended.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); viewDidChangeEffectiveAppearance(); settle() }

    /// A link ⌘-clicked in the terminal: local pages open as a browser tab, the rest in the default browser; ⌥ swaps
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

    func update(_: Session) { settle() }

    func focus() { ghostty.focus() }

    /// Columns × rows now; the last one seen anywhere sizes the next terminal before it's on screen.
    static var lastGrid: (cols: Int, rows: Int)? = {   // kept across launches: the window usually opens at the same size
        let g = UserDefaults.standard.array(forKey: "terminal.lastGrid") as? [Int] ?? []
        return g.count == 2 ? (g[0], g[1]) : nil
    }() {
        didSet { if let g = lastGrid, g != oldValue ?? (0, 0) { UserDefaults.standard.set([g.cols, g.rows], forKey: "terminal.lastGrid") } }
    }
    var gridSize: (cols: Int, rows: Int)? {
        if let g = ghostty.gridSize { Self.lastGrid = g; return g }
        return nil
    }

    /// What's on screen (tests, "copy context" fallback).
    var visibleText: String { ghostty.visibleText }

    /// Text dropped or dictated into the prompt.
    func insert(_ text: String) { ghostty.insert(text) }

    /// Right-click where the program in the terminal doesn't take the mouse itself, like Terminal's menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let g = ghostty, m = NSMenu()
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
    }

    // MARK: find (Edit › Find reaches the pane through the responder chain)
    private var findBar: FindBar?

    @objc func performFindPanelAction(_ sender: Any?) {
        let g = ghostty
        switch NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)) {
        case .next?: g.perform(action: "navigate_search:next")
        case .previous?: g.perform(action: "navigate_search:previous")
        case .setFindString?: g.perform(action: "search_selection")   // Ghostty answers with start_search and the text
        default: showFind(nil)
        }
    }

    private func showFind(_ needle: String?) {
        let g = ghostty
        let bar = findBar ?? {
            let b = FindBar()
            b.onSearch = { g.perform(action: "search:" + $0) }
            b.onStep = { g.perform(action: "navigate_search:" + ($0 ? "next" : "previous")) }
            b.onClose = { [weak self] in g.perform(action: "end_search"); self?.focus() }
            b.translatesAutoresizingMaskIntoConstraints = false; addSubview(b)
            NSLayoutConstraint.activate([b.topAnchor.constraint(equalTo: ghostty.topAnchor, constant: 8),
                                         b.trailingAnchor.constraint(equalTo: ghostty.trailingAnchor, constant: -14)])
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
