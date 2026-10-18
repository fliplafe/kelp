import AppKit
import Core
import TerminalKit

extension NSPasteboard.PasteboardType { static let krillPane = NSPasteboard.PasteboardType("dev.krill.pane") }

/// One terminal bound to one daemon session, with a draggable header showing agent status.
@MainActor
final class PaneView: NSView, NSDraggingSource {
    let sessionId: String
    let terminal = RemoteTerminalView(frame: .zero)
    private let header = NSView()
    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let restartButton = NSButton(title: "Restart", target: nil, action: nil)
    private let micButton = NSButton()
    private var lastOutput = Date()
    private var cacheTimer: Timer?
    private let summary = NSTextField(labelWithString: "")
    var onRestart: ((PaneView) -> Void)?
    private let dropHint = NSView()
    var onClose: ((PaneView) -> Void)?
    var onFocus: ((PaneView) -> Void)?
    var onDrop: ((String, PaneView, DropEdge) -> Void)?

    enum DropEdge { case left, right, top, bottom }

    init(session: Session) {
        sessionId = session.id
        super.init(frame: .zero)
        wantsLayer = true
        header.wantsLayer = true
        dot.wantsLayer = true; dot.layer?.cornerRadius = 4
        title.font = .systemFont(ofSize: 11, weight: .medium); title.lineBreakMode = .byTruncatingTail
        closeButton.bezelStyle = .inline; closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close pane")
        closeButton.target = self; closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Close pane and end the session"
        restartButton.bezelStyle = .inline; restartButton.controlSize = .small; restartButton.target = self; restartButton.action = #selector(restartTapped)
        restartButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil); restartButton.imagePosition = .imageLeading
        micButton.bezelStyle = .inline; micButton.isBordered = false; micButton.target = self; micButton.action = #selector(dictate)
        micButton.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dictate prompt"); micButton.toolTip = "Dictate into the prompt (on-device)"
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor; summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for v in [dot, title, summary, restartButton, micButton, closeButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(v) }
        let menu = NSMenu()
        for (t, a) in [("Rename…", #selector(renameTapped)), ("Restart", #selector(restartTapped)), ("Copy Context", #selector(copyContext)),
                       ("Fork to New Worktree…", #selector(forkTapped)), ("Hand Off to Another Agent…", #selector(handoffTapped)), ("Close", #selector(closeTapped))] {
            menu.addItem(withTitle: t, action: a, keyEquivalent: "").target = self
        }
        header.menu = menu
        for v in [header, terminal, dropHint] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        dropHint.wantsLayer = true; dropHint.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor; dropHint.isHidden = true
        dropHint.translatesAutoresizingMaskIntoConstraints = true
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 22),
            dot.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8), dot.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6), title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            summary.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10), summary.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: restartButton.leadingAnchor, constant: -6),
            restartButton.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -6), restartButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            micButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6), micButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6), closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor), terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor), terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes([.krillPane, .fileURL, .png, .tiff])
        applyAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(applyAppearance), name: UserDefaults.didChangeNotification, object: nil)
        update(session)

        let id = session.id
        terminal.onInput = { AppModel.shared.write(session: id, $0) }
        terminal.onResize = { AppModel.shared.resize(session: id, cols: $0, rows: $1) }
        terminal.onFocus = { [weak self] in if let s = self { s.onFocus?(s) } }
        Task { await AppModel.shared.attach(session: id) { [weak self] in self?.terminal.feed($0); self?.lastOutput = Date() } }
        cacheTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tickCache() } }
    }
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { cacheTimer?.invalidate(); AppModel.shared.detach(session: sessionId) }

    /// Claude's prompt cache lives ~5 minutes after the last activity; show what's left while the agent waits.
    private func tickCache() {
        guard let s = AppModel.shared.session(sessionId), s.agent == "claude", s.status == .done || s.status == .waiting || s.status == .idle, !Dictation.shared.isRecording else { return }
        let left = 300 - Date().timeIntervalSince(lastOutput)
        let base = s.summary.isEmpty ? s.status.label : s.summary
        summary.stringValue = left > 0 ? "\(base)  ·  cache \(Int(left) / 60):\(String(format: "%02d", Int(left) % 60))" : base
        summary.toolTip = "Prompt cache: replying within 5 minutes of the last message is cheaper and faster."
    }

    @objc private func dictate() {
        let d = Dictation.shared
        if d.isRecording {
            let t = d.stop(); micButton.contentTintColor = nil; micButton.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
            if let s = AppModel.shared.session(sessionId) { update(s) }
            guard !t.isEmpty else { return }
            Task { await AppModel.shared.call("session.send", .obj(["id": .string(sessionId), "text": .string(t), "enter": false])) }
            focus(); return
        }
        d.onUpdate = { [weak self] t in self?.summary.stringValue = "🎙 " + t }
        Task {
            do {
                try await d.start()
                micButton.contentTintColor = .systemRed; micButton.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
                summary.stringValue = "🎙 Listening… click the mic again to insert"
            } catch {
                let a = NSAlert(error: error); _ = await runSheet(a)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            header.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); viewDidChangeEffectiveAppearance() }

    /// Font and colors: Settings first, then the Ghostty config, then system defaults.
    @objc private func applyAppearance() {
        let d = UserDefaults.standard
        let g = d.object(forKey: "ghosttyTheme") as? Bool ?? true ? GhosttyConfig.load() : nil
        let size = d.object(forKey: "terminalFontSize") as? Double ?? g?.fontSize ?? 13
        let name = (d.string(forKey: "terminalFont")).flatMap { $0.isEmpty ? nil : $0 } ?? g?.fontFamily
        terminal.setFont(name: name, size: CGFloat(size))
        func color(_ h: String?) -> NSColor? { h.flatMap(GhosttyConfig.rgb).map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) } }
        if let bg = color(g?.background), let fg = color(g?.foreground) { terminal.apply(theme: TerminalTheme(background: bg, foreground: fg)) }
    }

    @objc private func closeTapped() { onClose?(self) }
    @objc private func restartTapped() { onRestart?(self) }
    @objc private func renameTapped() {
        let cur = AppModel.shared.session(sessionId)?.title ?? ""
        guard let t = prompt("Rename tab", "Leave empty to name it from the prompt automatically.", initial: cur) else { return }
        Task { await AppModel.shared.call("session.rename", .obj(["id": .string(sessionId), "title": .string(t)])) }
    }
    @objc private func copyContext() {
        Task {
            guard let t = await AppModel.shared.call("session.context", .obj(["id": .string(sessionId)]))?.string else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
        }
    }
    @objc private func forkTapped() { AgentActions.fork(sessionId) }
    @objc private func handoffTapped() { AgentActions.handoff(sessionId) }

    func update(_ s: Session) {
        let color: NSColor = switch s.status {
        case .working: .systemBlue
        case .waiting: .systemOrange
        case .done: .systemGreen
        case .idle: .systemGray
        case .exited: .systemRed
        }
        dot.layer?.backgroundColor = color.cgColor
        dot.toolTip = s.status.label
        title.stringValue = s.displayTitle + (s.unread ? "  •" : "")
        title.toolTip = s.command
        summary.stringValue = s.summary.isEmpty ? s.status.label : s.summary
        restartButton.isHidden = s.status != .exited
    }

    func focus() { terminal.focus() }

    // MARK: dragging this pane by its header
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard header.frame.contains(p) else { return super.mouseDragged(with: event) }
        let item = NSPasteboardItem(); item.setString(sessionId, forType: .krillPane)
        let di = NSDraggingItem(pasteboardWriter: item)
        di.setDraggingFrame(header.frame, contents: header.snapshot())
        beginDraggingSession(with: [di], event: event, source: self)
    }
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    // MARK: drop target: pane moves (edge zones) and file/image drops into the agent's prompt
    private func edge(_ info: NSDraggingInfo) -> DropEdge {
        let p = convert(info.draggingLocation, from: nil), w = bounds.width, h = bounds.height
        let dx = min(p.x, w - p.x) / w, dy = min(p.y, h - p.y) / h
        if dx < dy { return p.x < w / 2 ? .left : .right }
        return p.y < h / 2 ? .bottom : .top
    }
    private func hint(_ e: DropEdge) {
        let b = bounds
        dropHint.frame = switch e {
        case .left: NSRect(x: 0, y: 0, width: b.width / 2, height: b.height)
        case .right: NSRect(x: b.width / 2, y: 0, width: b.width / 2, height: b.height)
        case .top: NSRect(x: 0, y: b.height / 2, width: b.width, height: b.height / 2)
        case .bottom: NSRect(x: 0, y: 0, width: b.width, height: b.height / 2)
        }
        dropHint.isHidden = false
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.string(forType: .krillPane) != nil { hint(edge(sender)); return .move }
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.string(forType: .krillPane) != nil { hint(edge(sender)); return .move }
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHint.isHidden = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHint.isHidden = true
        let pb = sender.draggingPasteboard
        if let id = pb.string(forType: .krillPane) { onDrop?(id, self, edge(sender)); return true }
        // Text dropped from elsewhere goes into the prompt as-is.
        // Files and images go into the agent's prompt as paths.
        var paths = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.path) ?? []
        if paths.isEmpty, let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("krill-\(UUID().uuidString.prefix(8)).png")
            try? png.write(to: u); paths = [u.path]
        }
        guard !paths.isEmpty else { return false }
        AppModel.shared.write(session: sessionId, Data((paths.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ") + " ").utf8))
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
