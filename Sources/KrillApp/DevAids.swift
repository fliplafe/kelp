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
            if let f = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_OPEN"] { content.files?.openFile(f, line: 3) }
            if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_RUN"] != nil { runDevServer() }
            if let keys = ProcessInfo.processInfo.environment["KRILL_TYPE"] { typeKeys(keys) }
            if ProcessInfo.processInfo.environment["KRILL_TYPING_BENCH"] != nil, let f = content.files?.current {
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
            if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WINDOW"] == "composer" { newWorktree() }
            if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WINDOW"] == "chat", let w = AppModel.shared.worktree(content.worktreeId) {
                Task {
                    guard let id = (await AppModel.shared.call("chat.start", .obj(["worktreeId": .string(w.id)])))?["id"]?.string else { return }
                    content.workspace?.open(.chat(id))
                    await AppModel.shared.call("chat.send", .obj(["id": .string(id), "text": "Add a unit test for the parser"]))
                }
            }
            if let sel = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_DESIGN"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.content.browser?.toggleDesign()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.content.browser?.debugClick(sel) } }
            }
            if ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_FANOUT"] != nil, let g = FanoutController.groups().first {
                FanoutController.show(ids: g.value.map(\.id), title: g.key)
                if let row = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_FANOUT"].flatMap(Int.init) { FanoutController.open.last?.select(row) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5)) { [self] in
                let want = ProcessInfo.processInfo.environment["KRILL_SNAPSHOT_WINDOW"].map { ["dashboard": "Agents", "history": "Session History", "settings": "Settings", "composer": "New Workspace"][$0] ?? $0 }
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
                if let d = content.diff { print("DIFF", d.debugInfo) }
                for p in content.workspace?.visiblePanes ?? [] { print("PANE", p.sessionId.prefix(8), p.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)) }
                exit(0)
            }
        }
    }
}

extension AppDelegate {
    /// Dev aid: real key events through NSApp (menus, key equivalents, the terminal's keyDown/IME path).
    /// "echo hi\r" types text; "{cmd+t}" / "{cmd+\\}" press shortcuts.
    func typeKeys(_ spec: String) {
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
            "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49, "\r": 36, "-": 27, "\\": 42]
        var events: [(String, NSEvent.ModifierFlags)] = []
        var rest = Substring(spec.replacingOccurrences(of: "\\r", with: "\r"))
        while let c = rest.first {
            if c == "{", let end = rest.firstIndex(of: "}") {
                let combo = rest[rest.index(after: rest.startIndex)..<end].split(separator: "+")
                var mods: NSEvent.ModifierFlags = []
                for m in combo.dropLast() { mods.insert(["cmd": .command, "shift": .shift, "opt": .option, "ctrl": .control][String(m)] ?? []) }
                let key = String(combo.last ?? "")
                events.append((mods.contains(.shift) ? key.uppercased() : key, mods)); rest = rest[rest.index(after: end)...]
            } else { events.append((String(c), [])); rest = rest.dropFirst() }
        }
        window.makeKeyAndOrderFront(nil)
        content.workspace?.visiblePanes.first?.focus()
        for (i, (ch, mods)) in events.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(i) * 0.05) { [self] in
                let code = ch.count == 1 ? codes[Character(ch.lowercased())] ?? 0 : 0
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                                isARepeat: false, keyCode: code) { NSApp.sendEvent(e) }
                }
            }
        }
    }
}

extension NSView {
    func allSubviews<T: NSView>(of t: T.Type) -> [T] { subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.allSubviews(of: t) } }
}
