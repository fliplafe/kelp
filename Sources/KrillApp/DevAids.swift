import AppKit

/// Developer aids driven by environment variables; inert in normal use.
///   KRILL_SNAPSHOT=/x.png  render the window to a PNG and quit (no screen-recording permission needed)
///   KRILL_SNAPSHOT_MODE / _WORKTREE / _OPEN / _RUN / _WINDOW / _DESIGN / _FANOUT / _DELAY  set the scene first
///   KRILL_TYPING_BENCH=1|raw  time synthetic keystrokes in the open file
extension AppDelegate {
    /// Dev aid: KRILL_SNAPSHOT=/path.png writes the window contents and quits (works without screen-recording permission).
    /// KRILL_SNAPSHOT_MODE=Review|Terminals picks the mode first.
    /// KRILL_HANG_WATCH=1: logs every main-thread stall over 150 ms (what users feel as freezes).
    static func watchHangs() {
        guard ProcessInfo.processInfo.environment["KRILL_HANG_WATCH"] != nil else { return }
        Thread.detachNewThread {
            while true {
                let sent = Date()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 1) == .timedOut {   // stuck: record where the main thread is
                    let out = FileManager.default.temporaryDirectory.appendingPathComponent("krill-hang-\(getpid()).txt").path
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    p.arguments = ["\(getpid())", "1", "-file", out]; try? p.run(); p.waitUntilExit()
                    print("HANG-SAMPLE " + out)
                    sem.wait()
                }
                let ms = Date().timeIntervalSince(sent) * 1000
                if ms > 150 { print(String(format: "HANG %.0f ms", ms)) }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    func snapshotLater(_ path: String) {
        let env = ProcessInfo.processInfo.environment
        if env["KRILL_SNAPSHOT_DARK"] == nil { NSApp.appearance = NSAppearance(named: .aqua) }   // cacheDisplay mixes appearances otherwise
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [self] in
            main.window?.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 900), display: true); main.window?.contentView?.layoutSubtreeIfNeeded()
            if let p = env["KRILL_SNAPSHOT_INSPECTOR"] { main.showInspector(panel: p) }
            if let u = env["KRILL_SNAPSHOT_OPEN"] { for x in u.split(separator: "|") { Workbench.open(String(x)) } }
            if let keys = env["KRILL_TYPE"] { typeKeys(keys) }
            // KRILL_SWITCH="a,b,a": switch workspaces (by name or branch) every 0.7 s, timing each switch.
            if let names = env["KRILL_SWITCH"]?.split(separator: ",") {
                for (i, n) in names.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(i) * 0.7) {
                        guard let w = AppModel.shared.worktrees.first(where: { $0.displayName == n || $0.branch == n }) else { print("SWITCH no \(n)"); return }
                        let t0 = Date()
                        Workbench.show(workspace: w.id)
                        self.main.window?.contentView?.layoutSubtreeIfNeeded(); self.main.window?.displayIfNeeded()
                        print(String(format: "SWITCH %@ %.0f ms", String(n), Date().timeIntervalSince(t0) * 1000))
                    }
                }
            }
            switch env["KRILL_SNAPSHOT_WINDOW"] {
            case "dashboard": showDashboard()
            case "history": showHistory()
            case "settings": SettingsWindow.show(section: env["KRILL_SNAPSHOT_SECTION"])
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (env["KRILL_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5)) { [self] in
                let want = env["KRILL_SNAPSHOT_WINDOW"].map { ["dashboard": "Agents", "history": "Session History", "settings": "Settings"][$0] ?? $0 }
                // The frame view includes the title bar and toolbar.
                let picked = env["KRILL_SNAPSHOT_WINDOW"] == "settings" ? SettingsWindow.window : NSApp.windows.filter(\.isVisible).last { want != nil && $0.title.hasPrefix(want ?? "") }
                guard let w = picked ?? main.window,
                      let v = w.contentView?.superview ?? w.contentView else { exit(2) }
                if want != nil { print("WINDOW", w.title, w.frame) }
                // Render the layer tree (what the compositor shows); cacheDisplay misses layer-only content.
                v.layoutSubtreeIfNeeded(); v.displayIfNeeded()
                let scale = w.backingScaleFactor, size = v.bounds.size
                if let layer = v.layer, let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                                            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: scale, y: scale)
                    var bg = NSColor.windowBackgroundColor.cgColor; NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { bg = NSColor.windowBackgroundColor.cgColor }
                    ctx.setFillColor(bg); ctx.fill(CGRect(origin: .zero, size: size))   // the window frame paints this on screen
                    if v.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
                    layer.render(in: ctx)
                    if let img = ctx.makeImage() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
                }
                for p in v.allSubviews(of: PaneView.self) { print("PANE", p.sessionId.prefix(8), p.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)) }
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
        main.window?.makeKeyAndOrderFront(nil)
        Workbench.editor?.focusSelected()
        for (i, (ch, mods)) in events.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(i) * 0.05) { [self] in
                let code = ch.count == 1 ? codes[Character(ch.lowercased())] ?? 0 : 0
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: main.window?.windowNumber ?? 0, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                                isARepeat: false, keyCode: code) { NSApp.sendEvent(e) }
                }
            }
        }
    }
}

extension NSView {
    func allSubviews<T: NSView>(of t: T.Type) -> [T] { subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.allSubviews(of: t) } }
}
