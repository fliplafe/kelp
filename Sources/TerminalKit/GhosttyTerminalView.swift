#if canImport(GhosttyKit)
import AppKit
import GhosttyKit

// Terminal backend on libghostty (Metal rendering, Ghostty's input and selection). Input handling follows
// Ghostty's own macOS SurfaceView (MIT): https://github.com/ghostty-org/ghostty/tree/main/macos/Sources/Ghostty

/// One libghostty app per process; surfaces (terminal views) hang off it.
@MainActor
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()
    public private(set) var app: ghostty_app_t?

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else { return }
        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)          // the user's Ghostty theme, font, cursor…
        // App shortcuts (⌘T, ⌘D, ⌘W…) belong to Krill; Ghostty keeps only terminal ones.
        let overrides = """
        keybind = clear
        keybind = super+c=copy_to_clipboard
        keybind = super+v=paste_from_clipboard
        keybind = super+a=select_all
        keybind = super+equal=increase_font_size:1
        keybind = super+plus=increase_font_size:1
        keybind = super+minus=decrease_font_size:1
        keybind = super+zero=reset_font_size
        keybind = super+k=clear_screen
        keybind = shift+page_up=scroll_page_up
        keybind = shift+page_down=scroll_page_down
        keybind = super+home=scroll_to_top
        keybind = super+end=scroll_to_bottom
        confirm-close-surface = false
        clipboard-paste-protection = false
        window-padding-x = 6
        window-padding-y = 4
        """
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("krill-ghostty-\(getpid()).conf")
        try? overrides.write(to: f, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, f.path)
        ghostty_config_finalize(cfg)

        var rt = ghostty_runtime_config_s()
        rt.userdata = nil
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { if let a = GhosttyRuntime.shared.app { ghostty_app_tick(a) } } } }
        rt.action_cb = { _, target, action in
            MainActor.assumeIsolated { GhosttyRuntime.shared.handle(target, action) }
        }
        rt.read_clipboard_cb = { ud, _, state, mimes, count, _ in
            MainActor.assumeIsolated { GhosttyTerminalView.from(ud)?.readClipboard(state: state, mimes: mimes, count: count) ?? GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        }
        rt.confirm_read_clipboard_cb = { ud, _, state, _ in
            MainActor.assumeIsolated { if let v = GhosttyTerminalView.from(ud), let s = v.surface { ghostty_surface_deny_clipboard_request(s, state) } }
        }
        rt.write_clipboard_cb = { _, _, contents, count, _ in
            guard let contents, count > 0 else { return }
            var text: String?
            for i in 0..<count {
                let c = contents[i]
                guard let mime = c.mime.map({ String(cString: $0) }), mime.hasPrefix("text/plain"), let data = c.data else { continue }
                text = String(bytes: UnsafeRawBufferPointer(start: data, count: c.len), encoding: .utf8)
            }
            if let text { DispatchQueue.main.async { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } }
        }
        rt.close_surface_cb = { ud, _ in
            MainActor.assumeIsolated { GhosttyTerminalView.from(ud)?.onExit?() }
        }
        app = ghostty_app_new(&rt, cfg)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let a = GhosttyRuntime.shared.app { ghostty_app_set_focus(a, true) } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let a = GhosttyRuntime.shared.app { ghostty_app_set_focus(a, false) } }
        }
    }

    private func handle(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        let view: GhosttyTerminalView? = target.tag == GHOSTTY_TARGET_SURFACE
            ? target.target.surface.flatMap { GhosttyTerminalView.from(ghostty_surface_userdata($0)) } : nil
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let t = action.action.set_title.title { view?.onTitle?(String(cString: t)) }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let p = u.url else { return false }
            if let s = String(bytes: UnsafeRawBufferPointer(start: p, count: Int(u.len)), encoding: .utf8), let url = URL(string: s) { if let h = view?.onOpenURL { h(url) } else { NSWorkspace.shared.open(url) } }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            if let view { view.cursor = GhosttyTerminalView.cursor(for: action.action.mouse_shape); view.window?.invalidateCursorRects(for: view) }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            view?.cellSize = NSSize(width: Double(action.action.cell_size.width), height: Double(action.action.cell_size.height))
            return true
        case GHOSTTY_ACTION_RING_BELL:
            return true   // agents ring constantly; status dots carry that signal
        default:
            return false
        }
    }
}

@MainActor
public final class GhosttyTerminalView: NSView, @preconcurrency NSTextInputClient {
    public private(set) var surface: ghostty_surface_t?
    public var onTitle: ((String) -> Void)?
    public var onOpenURL: ((URL) -> Void)?
    public var onExit: (() -> Void)?
    public var onFocus: (() -> Void)?
    var cellSize = NSSize(width: 8, height: 16)
    var cursor: NSCursor = .iBeam
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var trackingArea: NSTrackingArea?

    public static var isAvailable: Bool { GhosttyRuntime.shared.app != nil }

    /// Runs `command` (through the login shell, like Ghostty) in `cwd` with extra environment.
    public init(command: String, cwd: String, env: [String: String] = [:]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        guard let app = GhosttyRuntime.shared.app else { return }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.wait_after_command = false
        let cKeys = env.keys.map { strdup($0) }, cValues = env.keys.map { strdup(env[$0] ?? "") }
        defer { (cKeys + cValues).forEach { free($0) } }
        var vars = zip(cKeys, cValues).map { ghostty_env_var_s(key: $0, value: $1) }
        surface = command.withCString { c in cwd.withCString { d in
            vars.withUnsafeMutableBufferPointer { vp in
                cfg.command = c; cfg.working_directory = d
                cfg.env_vars = vp.baseAddress; cfg.env_var_count = vp.count
                return ghostty_surface_new(app, &cfg)
            }
        } }
    }
    public required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    static func from(_ ud: UnsafeMutableRawPointer?) -> GhosttyTerminalView? {
        guard let ud else { return nil }
        return Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
    }

    // MARK: size, focus

    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        onFocus?(); return true
    }
    public override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }
    public func focus() { window?.makeFirstResponder(self) }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateSize() }
    public override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); updateSize() }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        updateSize()
    }
    private func updateSize() {
        guard let surface, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let fb = convertToBacking(bounds)
        ghostty_surface_set_content_scale(surface, fb.width / bounds.width, fb.height / bounds.height)
        ghostty_surface_set_size(surface, UInt32(fb.width), UInt32(fb.height))
    }

    public override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: .arrow
        default: .iBeam
        }
    }

    public override func updateTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self)
        addTrackingArea(t); trackingArea = t
        super.updateTrackingAreas()
    }

    // MARK: text access

    /// Visible screen text (tests, "send selection").
    public var visibleText: String { readText(GHOSTTY_POINT_VIEWPORT) }
    public var selection: String? {
        guard let surface else { return nil }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        return String(cString: t.text)
    }
    private func readText(_ tag: ghostty_point_tag_e) -> String {
        guard let surface else { return "" }
        var t = ghostty_text_s()
        let sel = ghostty_selection_s(top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                                      bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &t) else { return "" }
        defer { ghostty_surface_free_text(surface, &t) }
        return String(cString: t.text)
    }
    /// Type text as if pasted by the user (used for drops into the prompt).
    public func insert(_ text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }

    // MARK: mouse

    static func mods(_ f: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = f.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    public override func mouseDown(with e: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(e.modifierFlags))
    }
    public override func mouseUp(with e: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(e.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }
    public override func rightMouseDown(with e: NSEvent) {
        guard let surface, ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(e.modifierFlags)) else { return super.rightMouseDown(with: e) }
    }
    public override func rightMouseUp(with e: NSEvent) {
        guard let surface, ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(e.modifierFlags)) else { return super.rightMouseUp(with: e) }
    }
    public override func otherMouseDown(with e: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, Self.mods(e.modifierFlags))
    }
    public override func otherMouseUp(with e: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, Self.mods(e.modifierFlags))
    }
    public override func mouseMoved(with e: NSEvent) {
        guard let surface else { return }
        let p = convert(e.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y, Self.mods(e.modifierFlags))
    }
    public override func mouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    public override func rightMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    public override func otherMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    public override func mouseEntered(with e: NSEvent) { mouseMoved(with: e) }
    public override func mouseExited(with e: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(e.modifierFlags))
    }
    public override func scrollWheel(with e: NSEvent) {
        guard let surface else { return }
        var x = e.scrollingDeltaX, y = e.scrollingDeltaY
        let precise = e.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        let phases: [(NSEvent.Phase, Int32)] = [(.began, 1), (.stationary, 2), (.changed, 3), (.ended, 4), (.cancelled, 5), (.mayBegin, 6)]
        let momentum = phases.first { $0.0 == e.momentumPhase }?.1 ?? 0
        ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | (momentum << 1))
    }
    public override func pressureChange(with e: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(e.stage), Double(e.pressure))
    }

    // MARK: keyboard (ported from Ghostty's SurfaceView)

    private func keyEvent(_ e: NSEvent, _ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(e.keyCode)
        k.text = nil; k.composing = false
        k.mods = Self.mods(e.modifierFlags)
        k.consumed_mods = Self.mods((translationMods ?? e.modifierFlags).subtracting([.control, .command]))
        k.unshifted_codepoint = 0
        if e.type == .keyDown || e.type == .keyUp, let c = e.characters(byApplyingModifiers: [])?.unicodeScalars.first { k.unshifted_codepoint = c.value }
        return k
    }

    /// Control characters are encoded by Ghostty itself; function keys (PUA) carry no text.
    private static func characters(_ e: NSEvent) -> String? {
        guard let chars = e.characters else { return nil }
        if chars.count == 1, let s = chars.unicodeScalars.first {
            if s.value < 0x20 { return e.characters(byApplyingModifiers: e.modifierFlags.subtracting(.control)) }
            if s.value >= 0xF700 && s.value <= 0xF8FF { return nil }
        }
        return chars
    }

    @discardableResult
    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil, text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var k = keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        k.composing = composing
        if let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20 || text.count > 1 {
            return text.withCString { k.text = $0; return ghostty_surface_key(surface, k) }
        }
        return ghostty_surface_key(surface, k)
    }

    private func committedText(_ text: String) {
        guard let surface else { return }
        var k = ghostty_input_key_s()
        k.action = GHOSTTY_ACTION_PRESS; k.mods = GHOSTTY_MODS_NONE; k.consumed_mods = GHOSTTY_MODS_NONE
        text.withCString { k.text = $0; _ = ghostty_surface_key(surface, k) }
    }

    public override func keyDown(with event: NSEvent) {
        guard let surface else { interpretKeyEvents([event]); return }
        // Option-as-alt and friends: let Ghostty say which modifiers take part in translating to text.
        let tm = ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags))
        var translationMods = event.modifierFlags
        for (flag, bit) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER)] {
            if tm.rawValue & bit.rawValue != 0 { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent = translationMods == event.modifierFlags ? event : (NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationMods, timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event)
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        lastPerformKeyEvent = nil
        interpretKeyEvents([translationEvent])   // IMEs (Korean, Japanese, dead keys) speak through this
        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                if composing, text.count == 1, (text.unicodeScalars.first?.value ?? 0x20) < 0x20 { continue }
                if markedBefore { committedText(text) } else { keyAction(action, event: event, translationEvent: translationEvent, text: text) }
            }
        } else {
            if composing, let c = event.characters, c.count == 1, (c.unicodeScalars.first?.value ?? 0x20) < 0x20 { return }
            keyAction(action, event: event, translationEvent: translationEvent, text: Self.characters(translationEvent), composing: composing)
        }
    }

    public override func keyUp(with event: NSEvent) { keyAction(GHOSTTY_ACTION_RELEASE, event: event) }

    public override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let pressed = Self.mods(event.modifierFlags).rawValue & mod != 0
        keyAction(pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// ⌘-keys: Ghostty's own bindings (copy, paste, font size) go to the terminal; everything else to the menus.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let surface else { return false }
        var k = keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { k.text = $0; return ghostty_surface_key_is_binding(surface, k, &flags) }
        if isBinding { keyDown(with: event); return true }
        // Control-Return and Control-/ would otherwise be eaten by AppKit.
        if event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command), ["\r", "/"].contains(event.charactersIgnoringModifiers ?? "") {
            keyDown(with: event); return true
        }
        return false
    }

    // MARK: NSTextInputClient

    public func hasMarkedText() -> Bool { markedText.length > 0 }
    public func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let v = string as? NSAttributedString { markedText = NSMutableAttributedString(attributedString: v) }
        else if let v = string as? String { markedText = NSMutableAttributedString(string: v) }
        if keyTextAccumulator == nil { syncPreedit() }
    }
    public func unmarkText() { if markedText.length > 0 { markedText.mutableString.setString(""); syncPreedit() } }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func characterIndex(for point: NSPoint) -> Int { 0 }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let r = NSRect(x: x, y: bounds.height - y, width: 0, height: max(h, cellSize.height))
        return window?.convertToScreen(convert(r, to: nil)) ?? r
    }
    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if keyTextAccumulator != nil { keyTextAccumulator?.append(chars); return }
        if !chars.isEmpty { committedText(chars) }
    }
    public override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp { NSApp.sendEvent(current) }
    }
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let s = markedText.string
            s.withCString { ghostty_surface_preedit(surface, $0, UInt(s.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: clipboard

    func readClipboard(state: UnsafeMutableRawPointer?, mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int) -> ghostty_clipboard_read_result_e {
        guard let surface, let text = NSPasteboard.general.string(forType: .string) else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        let mime = strdup("text/plain;charset=utf-8"), data = strdup(text)
        defer { free(mime); free(data) }
        var content = ghostty_clipboard_content_s(mime: mime, data: data, len: text.utf8.count)
        withUnsafePointer(to: &content) { cp in
            var done = ghostty_clipboard_complete_s()
            done.contents = cp; done.contents_len = 1; done.confirmed = true
            ghostty_surface_complete_clipboard_request(surface, &done, state)
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }
}
#endif
