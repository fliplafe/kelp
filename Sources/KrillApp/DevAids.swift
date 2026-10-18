import AppKit

/// Developer aids driven by environment variables; inert in normal use.
///   KRILL_SNAPSHOT=/x.png  render the window to a PNG and quit (no screen-recording permission needed)
///   KRILL_SNAPSHOT_MODE / _WORKTREE / _OPEN / _RUN / _WINDOW / _DESIGN / _FANOUT / _DELAY  set the scene first
///   KRILL_TYPING_BENCH=1|raw  time synthetic keystrokes in the open file
extension AppDelegate {
    /// Dev aid: KRILL_SNAPSHOT=/path.png writes the window contents and quits (works without screen-recording permission).
    /// KRILL_SNAPSHOT_MODE=Review|Terminals picks the mode first.
    func snapshotLater(_ path: String) {
        NSApp.appearance = NSAppearance(named: .aqua)   // cacheDisplay mixes appearances otherwise
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [self] in
            window.setContentSize(NSSize(width: 1320, height: 840)); window.contentView?.layoutSubtreeIfNeeded()
            if let m = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_MODE"] { content.select(named: m) }
            if let f = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_OPEN"] { content.files.openFile(f, line: 3) }
            if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_RUN"] != nil { runDevServer() }
            if ProcessInfo.processInfo.environment["KRILL_TYPING_BENCH"] != nil, let f = content.files.current {
                // Dev aid: simulated typing in the middle of the open file.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if ProcessInfo.processInfo.environment["KRILL_TYPING_BENCH"] == "raw" { f.editor.onChange = nil }
                    let tv = f.editor.controller.textView!
                    let mid = (tv.string as NSString).length / 2
                    let t0 = Date()
                    for i in 0..<(ProcessInfo.processInfo.environment["KRILL_TYPING_N"].flatMap(Int.init) ?? 300) { tv.replaceCharacters(in: NSRange(location: mid + i, length: 0), with: "x") }
                    let t1 = Date()
                    for i in 0..<100 { tv.replaceCharacters(in: NSRange(location: mid + 300 + i, length: 0), with: "y"); tv.displayIfNeeded() }
                    print("TYPING edit-only \(String(format: "%.2f", t1.timeIntervalSince(t0) * 1000 / 300)) ms, edit+display \(String(format: "%.2f", Date().timeIntervalSince(t1) * 1000 / 100)) ms")
                }
            }
            if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WINDOW"] == "dashboard" { showDashboard() }
            if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WINDOW"] == "history" { showHistory() }
            if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WINDOW"] == "settings" { openSettings() }
            if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WINDOW"] == "chat", let w = AppModel.shared.worktree(content.worktreeId) {
                Task {
                    guard let id = (await AppModel.shared.call("chat.start", .obj(["worktreeId": .string(w.id)])))?["id"]?.string else { return }
                    ChatWindow.debugOpen(id: id, worktree: w)
                    await AppModel.shared.call("chat.send", .obj(["id": .string(id), "text": "Add a unit test for the parser"]))
                }
            }
            if let sel = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_DESIGN"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.content.browser.toggleDesign()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.content.browser.debugClick(sel) } }
            }
            if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_FANOUT"] != nil, let g = FanoutController.groups().first {
                FanoutController.show(ids: g.value.map(\.id), title: g.key)
                if let row = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_FANOUT"].flatMap(Int.init) { FanoutController.open.last?.select(row) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5)) { [self] in
                let want = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WINDOW"].map { ["dashboard": "Agents", "history": "Session History", "settings": "Settings", "chat": "Chat"][$0] ?? $0 }
                guard let v = (NSApp.windows.filter(\.isVisible).last { $0.title.hasPrefix("Fan-out") || (want != nil && $0.title.hasPrefix(want!)) } ?? window).contentView else { exit(2) }
                if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WINDOW"] != nil { print("WINDOW", v.window?.title ?? "", v.window?.frame ?? .zero, v.bounds) }
                // Render the layer tree (what the compositor shows); cacheDisplay misses layer-only content.
                v.layoutSubtreeIfNeeded(); v.displayIfNeeded()
                let scale = window.backingScaleFactor, size = v.bounds.size
                if let layer = v.layer, let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: scale, y: scale)
                    var bg = NSColor.windowBackgroundColor.cgColor; NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { bg = NSColor.windowBackgroundColor.cgColor }; ctx.setFillColor(bg); ctx.fill(CGRect(origin: .zero, size: size))   // the window frame paints this on screen
                    if !v.isFlipped { } else { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
                    layer.render(in: ctx)
                    if let img = ctx.makeImage() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
                }
                print("DIFF", content.diff.debugInfo)
                for p in content.workspace.view.allSubviews(of: PaneView.self) { print("PANE", p.sessionId.prefix(8), p.terminal.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)) }
                exit(0)
            }
        }
    }
}

extension NSView {
    func allSubviews<T: NSView>(of t: T.Type) -> [T] { subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.allSubviews(of: t) } }
}
