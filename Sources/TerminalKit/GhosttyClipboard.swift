import AppKit
import GhosttyKit

/// The clipboard as Ghostty asks for it: a paste, and a program reading or writing it.
extension GhosttyTerminalView {
    func readClipboard(state: UnsafeMutableRawPointer?, mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int) -> ghostty_clipboard_read_result_e {
        guard let surface, let text = TerminalPaste.text(from: .general) else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        let data = text.utf8CString   // its length goes along: a NUL inside the text must not cut it short
        data.withUnsafeBufferPointer { d in
            "text/plain;charset=utf-8".withCString { mime in
                var content = ghostty_clipboard_content_s(mime: mime, data: d.baseAddress, len: d.count - 1)
                withUnsafePointer(to: &content) { cp in
                    var done = ghostty_clipboard_complete_s()
                    // Not confirmed: Ghostty applies its policy (`clipboard-read = ask` for OSC 52 / Kitty reads, paste
                    // protection) and asks `confirmClipboard`.
                    done.contents = cp; done.contents_len = 1; done.confirmed = false
                    ghostty_surface_complete_clipboard_request(surface, &done, state)
                }
            }
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Ghostty asks before a paste that would run as typed (a line break, no bracketed paste) and before a program reads
    /// the clipboard or writes it the Kitty way. The paste goes through, unless a program put that text there: lines you
    /// never saw mustn't run on ⌘V. The rest is refused.
    func confirmClipboard(_ c: UnsafePointer<ghostty_clipboard_confirm_s>?, state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard let surface else { return }
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let c else { ghostty_surface_deny_clipboard_request(surface, state); return }
        if GhosttyRuntime.programCopy == NSPasteboard.general.changeCount {
            ghostty_surface_deny_clipboard_request(surface, state); onPasteRefused?(); return
        }
        var done = ghostty_clipboard_complete_s()
        done.contents = c.pointee.contents; done.contents_len = c.pointee.contents_len; done.confirmed = true
        ghostty_surface_complete_clipboard_request(surface, &done, state)
    }
}
