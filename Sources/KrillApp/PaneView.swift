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
        header.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        dot.wantsLayer = true; dot.layer?.cornerRadius = 4
        title.font = .systemFont(ofSize: 11, weight: .medium); title.lineBreakMode = .byTruncatingTail
        closeButton.bezelStyle = .inline; closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close pane")
        closeButton.target = self; closeButton.action = #selector(closeTapped)
        for v in [dot, title, closeButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(v) }
        for v in [header, terminal, dropHint] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        dropHint.wantsLayer = true; dropHint.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor; dropHint.isHidden = true
        dropHint.translatesAutoresizingMaskIntoConstraints = true
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 22),
            dot.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8), dot.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6), title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6), closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor), terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor), terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes([.krillPane, .fileURL, .png, .tiff])
        update(session)

        let id = session.id
        terminal.onInput = { AppModel.shared.write(session: id, $0) }
        terminal.onResize = { AppModel.shared.resize(session: id, cols: $0, rows: $1) }
        terminal.onFocus = { [weak self] in if let s = self { s.onFocus?(s) } }
        Task { await AppModel.shared.attach(session: id) { [weak self] in self?.terminal.feed($0) } }
    }
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { AppModel.shared.detach(session: sessionId) }

    @objc private func closeTapped() { onClose?(self) }

    func update(_ s: Session) {
        let color: NSColor = switch s.status {
        case .working: .systemBlue
        case .waiting: .systemOrange
        case .done: .systemGreen
        case .idle: .systemGray
        case .exited: .systemRed
        }
        dot.layer?.backgroundColor = color.cgColor
        title.stringValue = (s.agent ?? "shell") + (s.unread ? " •" : "") + "  —  " + s.status.rawValue
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
