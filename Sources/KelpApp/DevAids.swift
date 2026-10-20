import AppKit
import TerminalKit
import WebKit

/// Developer aids driven by environment variables; inert in normal use.
///   KELP_SNAPSHOT=/x.png  render the window to a PNG and quit (no screen-recording permission needed)
///   KELP_SNAPSHOT_MODE / _WORKTREE / _OPEN / _RUN / _WINDOW / _DESIGN / _FANOUT / _DELAY  set the scene first
///   KELP_TYPING_BENCH=1|raw  time synthetic keystrokes in the open file
extension AppDelegate {
    /// Dev aid: KELP_SNAPSHOT=/path.png writes the window contents and quits (works without screen-recording permission).
    /// KELP_SNAPSHOT_MODE=Review|Terminals picks the mode first.
    /// KELP_HANG_WATCH=1: logs every main-thread stall over 150 ms (what users feel as freezes).
    static func watchHangs() {
        guard ProcessInfo.processInfo.environment["KELP_HANG_WATCH"] != nil else { return }
        Thread.detachNewThread {
            while true {
                let sent = Date()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 1) == .timedOut {   // stuck: record where the main thread is
                    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-hang-\(getpid()).txt").path
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
        if env["KELP_SNAPSHOT_DARK"] == nil { NSApp.appearance = NSAppearance(named: .aqua) }   // cacheDisplay mixes appearances otherwise
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [self] in
            main.window?.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 900), display: true); main.window?.contentView?.layoutSubtreeIfNeeded()
            print("FRAME", main.window?.frame ?? .zero, main.window?.contentView?.superview?.bounds ?? .zero)
            if let p = env["KELP_SNAPSHOT_INSPECTOR"] { main.showInspector(panel: p) }
            // KELP_SNAPSHOT_SIZE=1000x760: the window's content size (people's windows are rarely 1440 wide).
            if let s = env["KELP_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), s.count == 2 {
                main.window?.setContentSize(NSSize(width: s[0], height: s[1]))
            }
            if let u = env["KELP_SNAPSHOT_OPEN"] { for x in u.split(separator: "|") { Workbench.open(String(x)) } }
            // KELP_SNAPSHOT_SHEET=clone|create[=text]: Add Project's sheets (the open panel itself is another process),
            // with text: filled in and started.
            if env["KELP_SNAPSHOT_SHEET"] == "onboarding" { OnboardingSheet.show() } else if let s = env["KELP_SNAPSHOT_SHEET"] {
                let p = s.split(separator: "=", maxSplits: 1).map(String.init)
                NewProjectSheet.show(p[0] == "create" ? .create : p[0] == "remote" ? .remote : .clone, start: p.count > 1 ? p[1] : nil)
            }
            if let keys = env["KELP_TYPE"] { typeKeys(keys) }
            // KELP_CLICK="Workspace 2|calc.py": real mouse clicks (via NSApp.sendEvent) on visible text, 0.8 s apart.
            if let targets = env["KELP_CLICK"]?.split(separator: "|") {
                let start = env["KELP_CLICK_DELAY"].flatMap(Double.init) ?? 0.3   // panels that load later need longer
                for (i, t) in targets.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(i) * 0.8) { [self] in click(text: String(t)) }
                }
            }
            // KELP_TERM_HOVER="app.py:2": the pointer rests on that text in a terminal (path previews).
            #if canImport(GhosttyKit)
            if let t = env["KELP_TERM_HOVER"], let v = main.window?.contentView {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let g = v.allSubviews(of: GhosttyTerminalView.self).first, let p = g.location(of: t),
                          let e = NSEvent.mouseEvent(with: .mouseMoved, location: g.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                                     windowNumber: v.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { print("TERM_HOVER no", t); return }
                    g.mouseMoved(with: e); print("TERM_HOVER", t, p)
                }
            }
            #endif
            // KELP_MOVE="Workspace 1": the pointer comes to rest on that text (hover cards): a mouse-moved event for whatever tracks it.
            if let t = env["KELP_MOVE"], let w = main.window, let v = w.contentView { Self.move(t, in: v, window: w) }
            // KELP_SWITCH="a,b,a": switch workspaces (by name or branch) every 0.7 s, timing each switch.
            if let names = env["KELP_SWITCH"]?.split(separator: ",") {
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
            switch env["KELP_SNAPSHOT_WINDOW"] {
            case "history": showHistory()
            case "settings": SettingsWindow.show(section: env["KELP_SNAPSHOT_SECTION"])
            default: break
            }
            // A run-loop timer rather than the main queue: it also fires while a modal sheet runs.
            RunLoop.main.add(Timer(timeInterval: env["KELP_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5, repeats: false) { _ in MainActor.assumeIsolated { [self] in
                let want = env["KELP_SNAPSHOT_WINDOW"].map { ["history": "Session History", "settings": "Settings"][$0] ?? $0 }
                // The frame view includes the title bar and toolbar.
                let picked = env["KELP_SNAPSHOT_WINDOW"] == "settings" ? SettingsWindow.window : NSApp.windows.filter(\.isVisible).last { want != nil && $0.title.hasPrefix(want ?? "") }
                guard let w = picked ?? main.window,
                      let v = w.contentView?.superview ?? w.contentView else { exit(2) }
                if want != nil { print("WINDOW", w.title, w.frame) }
                print("WINDOWS", NSApp.windows.filter(\.isVisible).map { "\($0.title.isEmpty ? "-" : $0.title)(\(type(of: $0)))" }.joined(separator: ", "))
                if let s = w.attachedSheet {
                    print("SHEET", s.className, (s.contentView?.allSubviews(of: NSTextField.self) ?? []).map(\.stringValue).filter { !$0.isEmpty })
                    // Its own window: drawn next to the snapshot as "<name>-sheet.png".
                    if let sv = s.contentView?.superview ?? s.contentView { Self.render(sv, scale: s.backingScaleFactor, to: path.replacingOccurrences(of: ".png", with: "-sheet.png")) }
                }
                // KELP_HOVER="calc.py|Changes": a mouse-entered event for the views showing these texts (hover states can't be
                // reached otherwise without moving the user's pointer).
                for text in (env["KELP_HOVER"] ?? "").split(separator: "|").map(String.init) { Self.hover(text, in: v, window: w) }
                Self.render(v, scale: w.backingScaleFactor, to: path)
                // A popover (limits details…) is its own window: next to the snapshot, as "<name>-popover.png".
                // An alert shown on its own (a background app has no window to put the sheet on): "<name>-alert.png".
                for a in NSApp.windows where a.isVisible && a.className.contains("AlertPanel") {
                    print("ALERT", (a.contentView?.allSubviews(of: NSTextField.self) ?? []).map(\.stringValue).filter { !$0.isEmpty })
                    if let av = a.contentView?.superview ?? a.contentView { Self.render(av, scale: a.backingScaleFactor, to: path.replacingOccurrences(of: ".png", with: "-alert.png")) }
                }
                for pop in NSApp.windows where pop.isVisible && pop.className.contains("Popover") {
                    if let pv = pop.contentView?.superview ?? pop.contentView { Self.render(pv, scale: pop.backingScaleFactor, to: path.replacingOccurrences(of: ".png", with: "-popover.png")) }
                }
                // In another language: menu items still in English (their text isn't in Localizable.xcstrings yet).
                if Bundle.main.preferredLocalizations.first != "en" {
                    func walk(_ m: NSMenu) {
                        for i in m.items where !i.isSeparatorItem {
                            if let s = i.submenu { if s !== NSApp.servicesMenu { walk(s) }; continue }
                            if i.title.range(of: "[А-яЁё]", options: .regularExpression) == nil, i.title.range(of: "[a-z]{3}", options: .regularExpression) != nil { print("UNTRANSLATED", i.title) }
                        }
                    }
                    NSApp.mainMenu.map(walk)
                }
                for p in v.allSubviews(of: PaneView.self) { print("PANE", p.sessionId.prefix(8), p.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)) }
                // Web content is drawn out of process and may be missing from the PNG: report what the page really shows
                // (not under a sheet: its run loop may not deliver the script's answer).
                let webs = v.allSubviews(of: WKWebView.self)
                guard !webs.isEmpty, w.attachedSheet == nil else { exit(0) }
                var left = webs.count
                for (i, web) in webs.enumerated() {
                    web.evaluateJavaScript("document.body ? [document.body.innerText.length, document.querySelectorAll('svg').length] : [-1, 0]") { r, _ in
                        let n = (r as? [Int]) ?? []
                        let visible = web.window != nil && !web.isHiddenOrHasHiddenAncestor
                        print("WEB", web.url?.absoluteString ?? "-", "frame", web.frame.size, "visible", visible, "text", n.first ?? -1, "svg", n.last ?? 0)
                        // What the page draws, as "<name>-web<i>.png" (it's out of process, so not in the window's PNG).
                        guard visible else { left -= 1; if left == 0 { exit(0) }; return }
                        web.takeSnapshot(with: nil) { img, _ in
                            if let t = img?.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                                try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-web\(i).png")))
                            }
                            left -= 1; if left == 0 { exit(0) }
                        }
                    }
                }
            } }, forMode: .common)
        }
    }
}

extension AppDelegate {
    /// The nearest view above the label `text` that tracks the mouse gets mouseEntered, like a real pointer would send.
    static func move(_ text: String, in root: NSView, window: NSWindow) {
        guard let label = root.allSubviews(of: NSTextField.self).first(where: { $0.stringValue == text }) else { print("MOVE no", text); return }
        let p = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: nil)
        guard let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
        var v: NSView? = label
        while let x = v {
            for a in x.trackingAreas where a.options.contains(.mouseMoved) { (a.owner as? NSResponder)?.mouseMoved(with: e); print("MOVE", text, "→", type(of: a.owner as Any)); return }
            v = x.superview
        }
        print("MOVE nothing tracks", text)
    }

    static func hover(_ text: String, in root: NSView, window: NSWindow) {
        guard let label = root.allSubviews(of: NSTextField.self).first(where: { $0.stringValue == text }) else { print("HOVER no", text); return }
        var v: NSView? = label
        while let x = v, x.trackingAreas.isEmpty { v = x.superview }
        guard let target = v, let e = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        else { print("HOVER nothing tracks", text); return }
        target.mouseEntered(with: e)
        print("HOVER", text, "→", type(of: target))
    }

    /// Dev aid: real key events through NSApp (menus, key equivalents, the terminal's keyDown/IME path).
    /// "echo hi\r" types text; "{cmd+t}" / "{cmd+\\}" press shortcuts; "{wait}" pauses a second (async UI).
    func typeKeys(_ spec: String) {
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
            "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49, "\r": 36, "-": 27, "\\": 42, "/": 44, "?": 44,
            // ЙЦУКЕН on the same keys, to press ⌘Ц the way a Russian layout sends it
            "й": 12, "ц": 13, "у": 14, "к": 15, "е": 17, "н": 16, "г": 32, "ш": 34, "щ": 31, "з": 35, "ф": 0, "ы": 1, "в": 2, "а": 3,
            "п": 5, "р": 4, "о": 38, "л": 40, "д": 37, "я": 6, "ч": 7, "с": 8, "м": 9, "и": 11, "т": 45, "ь": 46]
        var events: [(String, NSEvent.ModifierFlags)] = []
        var rest = Substring(spec.replacingOccurrences(of: "\\r", with: "\r"))
        while let c = rest.first {
            if c == "{", let end = rest.firstIndex(of: "}") {
                let combo = rest[rest.index(after: rest.startIndex)..<end].split(separator: "+")
                var mods: NSEvent.ModifierFlags = []
                for m in combo.dropLast() { mods.insert(["cmd": .command, "shift": .shift, "opt": .option, "ctrl": .control][String(m)] ?? []) }
                var key = String(combo.last ?? "")
                key = ["up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}", "tab": "\t", "esc": "\u{1B}",
                       "delete": "\u{7F}", "space": " ", "return": "\r"][key] ?? key
                events.append((mods.contains(.shift) ? key.uppercased() : key, mods)); rest = rest[rest.index(after: end)...]
            } else { events.append((String(c), [])); rest = rest.dropFirst() }
        }
        main.window?.makeKeyAndOrderFront(nil)
        Workbench.editor?.focusSelected()
        var at = 0.3
        for (ch, mods) in events {
            if ch == "wait", mods.isEmpty { at += 1; continue }
            at += 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [self] in
                let named: [String: UInt16] = ["\u{F700}": 126, "\u{F701}": 125, "\u{F702}": 123, "\u{F703}": 124, "\t": 48, "\u{1B}": 53, "\u{7F}": 51]
                let code = named[ch] ?? (ch.count == 1 ? codes[Character(ch.lowercased())] ?? 0 : 0)
                defer { if !mods.isEmpty { DispatchQueue.main.async { print("KEY", mods.rawValue, ch.unicodeScalars.map { String($0.value, radix: 16) }, "→", AppModel.shared.worktree(Workbench.shared.workspaceId)?.displayName ?? "-") } } }
                // In the background (launched from a shell) there's no key window, so menu items that go to the
                // responder chain (Find…, Copy) are disabled: send their action along the window's chain instead.
                if !NSApp.isActive, mods.contains(.command), let item = Self.menuItem(ch, mods), item.target == nil, let a = item.action,
                   main.window?.firstResponder?.tryToPerform(a, with: item) == true { return }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: (123...126).contains(code) ? mods.union([.numericPad, .function]) : mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: main.window?.windowNumber ?? 0, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                                isARepeat: false, keyCode: code) { NSApp.sendEvent(e) }
                }
            }
        }
    }
}

extension AppDelegate {
    static func menuItem(_ key: String, _ mods: NSEvent.ModifierFlags, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for i in menu?.items ?? [] {
            if let found = menuItem(key, mods, in: i.submenu) { return found }
            let m = i.keyEquivalentModifierMask.union(i.keyEquivalent != i.keyEquivalent.lowercased() ? .shift : [])
            if i.keyEquivalent.lowercased() == key.lowercased(), m.intersection([.command, .shift, .option, .control]) == mods { return i }
        }
        return nil
    }

    /// Render the layer tree (what the compositor shows); cacheDisplay misses layer-only content.
    static func render(_ v: NSView, scale: CGFloat, to path: String) {
        v.layoutSubtreeIfNeeded(); v.displayIfNeeded()
        let size = v.bounds.size
        guard let layer = v.layer, let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)
        var bg = NSColor.windowBackgroundColor.cgColor; NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { bg = NSColor.windowBackgroundColor.cgColor }
        ctx.setFillColor(bg); ctx.fill(CGRect(origin: .zero, size: size))   // the window frame paints this on screen
        if v.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
        layer.render(in: ctx)
        if let img = ctx.makeImage() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
    }

    /// A visible label's text, or "@x,y": a point in the window, from its top-left corner (SwiftUI content has no labels).
    func click(text: String) {
        guard let w = main.window, let root = w.contentView?.superview else { return }
        let p: NSPoint
        let right = text.hasPrefix("r@")   // "r@x,y": a right click (context menus)
        let text = right ? String(text.dropFirst()) : text
        if text.hasPrefix("@"), case let xy = text.dropFirst().split(separator: ",").compactMap({ Double($0) }), xy.count == 2 {
            p = NSPoint(x: xy[0], y: w.frame.height - xy[1])
        } else if let field = root.allSubviews(of: NSTextField.self).first(where: { $0.stringValue == text && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }) {
            p = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        } else { print("CLICK no \(text)"); return }
        // A real click makes what it hits first responder; a window in the background (launched from a shell) doesn't.
        var hit = root.hitTest(root.convert(p, from: nil))
        while let v = hit, !v.acceptsFirstResponder { hit = v.superview }
        if let hit { w.makeFirstResponder(hit) }
        for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(e) }
        }
        print("CLICK \(text) → workspace \(AppModel.shared.worktree(Workbench.shared.workspaceId)?.displayName ?? "-")")
    }
}

extension NSView {
    func allSubviews<T: NSView>(of t: T.Type) -> [T] { subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.allSubviews(of: t) } }
}
