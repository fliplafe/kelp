import AppKit
import GhosttyKit

// Trial task 1 from the plan: a window with a libghostty terminal running `claude`.
// PROBE_CMD overrides the command; PROBE_SECONDS > 0 prints the visible screen text after that long and quits
// (a check that works without screen-recording permission, since Metal content can't be snapshotted).

final class SurfaceView: NSView {
    var surface: ghostty_surface_t?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resize()
    }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); resize() }

    func resize() {
        guard let surface, let w = window else { return }
        let scale = w.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
    }

    override func keyDown(with e: NSEvent) {
        guard let surface else { return }
        var mods: UInt32 = 0
        if e.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if e.modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if e.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if e.modifierFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        let text = e.characters ?? ""
        text.withCString { ptr in
            var k = ghostty_input_key_s()
            k.action = e.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            k.mods = ghostty_input_mods_e(rawValue: mods)
            k.consumed_mods = ghostty_input_mods_e(rawValue: 0)
            k.keycode = UInt32(e.keyCode)
            k.text = text.isEmpty || e.modifierFlags.contains(.control) ? nil : ptr
            k.unshifted_codepoint = e.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
            k.composing = false
            _ = ghostty_surface_key(surface, k)
        }
    }
    override func becomeFirstResponder() -> Bool { if let surface { ghostty_surface_set_focus(surface, true) }; return true }

    /// Visible screen as text.
    func visibleText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
}

final class Probe: NSObject, NSApplicationDelegate {
    var app: ghostty_app_t?
    var window: NSWindow!
    let view = SurfaceView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else { fatalError("ghostty_init failed") }
        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)   // the user's Ghostty config: theme, font, keybinds
        ghostty_config_finalize(cfg)

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { ud in
            let me = Unmanaged<Probe>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { if let a = me.app { ghostty_app_tick(a) } }
        }
        rt.action_cb = { _, _, _ in false }
        rt.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        rt.confirm_read_clipboard_cb = { _, _, _, _ in }
        rt.write_clipboard_cb = { _, _, content, count, _ in
            guard let content, count > 0, let data = content.pointee.data else { return }
            let s = String(decoding: UnsafeRawBufferPointer(start: data, count: content.pointee.len), as: UTF8.self)
            DispatchQueue.main.async { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
        }
        rt.close_surface_cb = { _, _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
        app = ghostty_app_new(&rt, cfg)
        guard let app else { fatalError("ghostty_app_new failed") }

        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "libghostty probe"; window.contentView = view; window.center(); window.makeKeyAndOrderFront(nil)

        let cmd = ProcessInfo.processInfo.environment["PROBE_CMD"] ?? "claude"
        let cwd = FileManager.default.currentDirectoryPath
        var sc = ghostty_surface_config_new()
        sc.platform_tag = GHOSTTY_PLATFORM_MACOS
        sc.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        sc.userdata = Unmanaged.passUnretained(view).toOpaque()
        sc.scale_factor = window.backingScaleFactor
        let surface = cmd.withCString { c in cwd.withCString { d in
            sc.command = c; sc.working_directory = d
            return ghostty_surface_new(app, &sc)
        } }
        guard let surface else { fatalError("ghostty_surface_new failed") }
        view.surface = surface
        view.resize()
        window.makeFirstResponder(view)
        NSApp.activate()

        if let typed = ProcessInfo.processInfo.environment["PROBE_TYPE"] {   // simulate typing after the program is up
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let t = typed.replacingOccurrences(of: "\\r", with: "\r")
                t.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
            }
        }
        if let secs = ProcessInfo.processInfo.environment["PROBE_SECONDS"].flatMap(Double.init), secs > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                let size = ghostty_surface_size(surface)
                print("SIZE \(size.columns)x\(size.rows)  foreground pid \(ghostty_surface_foreground_pid(surface))")
                print("SCREEN-BEGIN\n\(self.view.visibleText().trimmingCharacters(in: .whitespacesAndNewlines))\nSCREEN-END")
                exit(0)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let probe = Probe()
NSApplication.shared.delegate = probe
NSApplication.shared.run()
