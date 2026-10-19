import AppKit
import Core
import TerminalKit

extension NSPasteboard.PasteboardType { static let krillPane = NSPasteboard.PasteboardType("dev.krill.pane") }

/// One terminal bound to one daemon session. libghostty renders it when available (attached via `krill attach`,
/// so the daemon keeps the process); SwiftTerm is the fallback. A slim header appears only inside splits.
@MainActor
final class PaneView: NSView, NSDraggingSource, NSMenuItemValidation {
    let sessionId: String
    private var termView = NSView()
    #if canImport(GhosttyKit)
    private var ghostty: GhosttyTerminalView?
    #endif
    private var swiftTerm: RemoteTerminalView?
    private let header = NSView()
    private let title = NSTextField(labelWithString: "")
    private let dot = StatusMark(size: 10)
    private let ended = NSStackView()
    private let dropHint = NSView()
    private var headerHeight: NSLayoutConstraint!
    private var lastActivity = Date()

    var onClose: ((PaneView) -> Void)?
    var onFocus: ((PaneView) -> Void)?
    var onRestart: ((PaneView) -> Void)?
    var onDrop: ((String, PaneView, DropEdge) -> Void)?
    var showsHeader = false { didSet { headerHeight.constant = showsHeader ? 24 : 0; header.isHidden = !showsHeader } }

    enum DropEdge { case left, right, top, bottom }

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
        buildHeader()
        buildEndedOverlay()
        for v in [header, termView, ended, dropHint] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        dropHint.translatesAutoresizingMaskIntoConstraints = true
        dropHint.wantsLayer = true; dropHint.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        dropHint.layer?.cornerRadius = 6; dropHint.isHidden = true
        headerHeight = header.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), headerHeight,
            termView.topAnchor.constraint(equalTo: header.bottomAnchor), termView.leadingAnchor.constraint(equalTo: leadingAnchor),
            termView.trailingAnchor.constraint(equalTo: trailingAnchor), termView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ended.centerXAnchor.constraint(equalTo: termView.centerXAnchor), ended.centerYAnchor.constraint(equalTo: termView.centerYAnchor)
        ])
        header.isHidden = true
        registerForDraggedTypes([.krillPane, .fileURL, .png, .tiff, .string])
        update(session)
    }
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { if swiftTerm != nil { AppModel.shared.detach(session: sessionId) } }

    private func buildTerminal(_ s: Session) {
        let id = s.id
        #if canImport(GhosttyKit)
        if Self.useGhostty {
            let krill = Bundle.main.bundleURL.appendingPathComponent(Bundle.main.bundleIdentifier == nil ? "krill" : "Contents/MacOS/krill").path
            let cmd = "'\(krill.replacingOccurrences(of: "'", with: "'\\''"))' attach \(id)"
            let g = GhosttyTerminalView(command: cmd, cwd: s.cwd, env: ["KRILL_SOCKET": Paths.socket.path, "KRILL_HOME": Paths.root.path])
            g.onFocus = { [weak self] in if let me = self { me.onFocus?(me) } }
            g.onExit = { [weak self] in self?.sessionEnded() }
            g.onSearch = { [weak self] in self?.searchEvent($0) }
            g.onOpenURL = { url in
                // ⌘-click: local pages open as a browser tab, the rest in the default browser.
                if url.host == "localhost" || url.host == "127.0.0.1" || url.isFileURL { Workbench.open(url.isFileURL ? TabURI.file(url.path) : url.absoluteString, split: .right) }
                else { NSWorkspace.shared.open(url) }
            }
            ghostty = g; termView = g
            return
        }
        #endif
        let t = RemoteTerminalView(frame: .zero)
        t.onInput = { AppModel.shared.write(session: id, $0) }
        t.onResize = { AppModel.shared.resize(session: id, cols: $0, rows: $1) }
        t.onFocus = { [weak self] in if let me = self { me.onFocus?(me) } }
        Task { await AppModel.shared.attach(session: id) { [weak self] in self?.swiftTerm?.feed($0); self?.lastActivity = Date() } }
        swiftTerm = t; termView = t
        applySwiftTermAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(applySwiftTermAppearance), name: UserDefaults.didChangeNotification, object: nil)
    }

    private func buildHeader() {
        header.wantsLayer = true
        title.font = .systemFont(ofSize: 11, weight: .medium); title.lineBreakMode = .byTruncatingTail; title.textColor = .secondaryLabelColor
        let close = NSButton(image: .symbol("xmark", "Close pane"), target: self, action: #selector(closeTapped))
        close.isBordered = false; close.symbolConfiguration = .init(pointSize: 9, weight: .semibold); close.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [dot, title, NSView(), close]); row.spacing = 6; row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: header.leadingAnchor), row.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                                     row.topAnchor.constraint(equalTo: header.topAnchor), row.bottomAnchor.constraint(equalTo: header.bottomAnchor)])
        header.toolTip = "Drag to move this pane; drop on an edge of another pane to split"
    }

    private func buildEndedOverlay() {
        let l = NSTextField(labelWithString: "Session ended"); l.font = .systemFont(ofSize: 13, weight: .medium); l.textColor = .secondaryLabelColor
        let b = NSButton(title: "Restart", target: self, action: #selector(restartTapped)); b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil); b.imagePosition = .imageLeading
        let c = NSButton(title: "Close", target: self, action: #selector(closeTapped)); c.bezelStyle = .rounded
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
            header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            ended.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); viewDidChangeEffectiveAppearance() }

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
        title.stringValue = AgentCatalog.displayName(s)
        dot.status = s.agent == "shell" ? nil : s.status; dot.unread = s.unread
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
        m.addItem(withTitle: "Copy", action: #selector(GhosttyTerminalView.copy(_:)), keyEquivalent: "").target = g
        m.items.last?.isEnabled = g.hasSelection; m.autoenablesItems = false
        m.addItem(withTitle: "Paste", action: #selector(GhosttyTerminalView.paste(_:)), keyEquivalent: "").target = g
        m.addItem(withTitle: "Select All", action: #selector(GhosttyTerminalView.selectAll(_:)), keyEquivalent: "").target = g
        m.addItem(.separator())
        m.add("Find…") { [weak self] in self?.showFind(nil) }
        m.addItem(.separator())
        m.add("Split Right") { [weak self] in self?.focus(); Workbench.editor?.splitFocused(.right) }
        m.add("Split Down") { [weak self] in self?.focus(); Workbench.editor?.splitFocused(.down) }
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

    // MARK: dragging this pane by its header
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard showsHeader, header.frame.contains(p) else { return super.mouseDragged(with: event) }
        let item = NSPasteboardItem(); item.setString(sessionId, forType: .krillPane)
        let di = NSDraggingItem(pasteboardWriter: item)
        di.setDraggingFrame(header.frame, contents: header.snapshot())
        beginDraggingSession(with: [di], event: event, source: self)
    }
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    // MARK: drops: panes (edge = split) and files/images/text into the agent's prompt
    private func edge(_ info: NSDraggingInfo) -> DropEdge {
        let p = convert(info.draggingLocation, from: nil), w = bounds.width, h = bounds.height
        let dx = min(p.x, w - p.x) / w, dy = min(p.y, h - p.y) / h
        if dx < dy { return p.x < w / 2 ? .left : .right }
        return p.y < h / 2 ? .bottom : .top
    }
    private func hint(_ e: DropEdge) {
        let b = bounds.insetBy(dx: 4, dy: 4)
        dropHint.frame = switch e {
        case .left: NSRect(x: b.minX, y: b.minY, width: b.width / 2, height: b.height)
        case .right: NSRect(x: b.midX, y: b.minY, width: b.width / 2, height: b.height)
        case .top: NSRect(x: b.minX, y: b.midY, width: b.width, height: b.height / 2)
        case .bottom: NSRect(x: b.minX, y: b.minY, width: b.width, height: b.height / 2)
        }
        dropHint.isHidden = false
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.string(forType: .krillPane) != nil { hint(edge(sender)); return .move }
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHint.isHidden = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHint.isHidden = true
        let pb = sender.draggingPasteboard
        if let id = pb.string(forType: .krillPane) { onDrop?(id, self, edge(sender)); return true }
        var paths = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.path) ?? []
        if paths.isEmpty, let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("krill-\(UUID().uuidString.prefix(8)).png")
            try? png.write(to: u); paths = [u.path]
        }
        if paths.isEmpty, let text = pb.string(forType: .string) { insert(text); return true }
        guard !paths.isEmpty else { return false }
        insert(paths.map(IDE.escapedPath).joined(separator: " ") + " ")
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
