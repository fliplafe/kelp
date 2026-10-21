import AppKit

/// A sheet on the main window (clone, SSH, first launch); `close()` ends it.
@MainActor
class SheetController: NSWindowController {
    init(width: CGFloat) {
        super.init(window: NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 10), styleMask: [.titled], backing: .buffered, defer: true))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// False when there's no window to put it on. `ended` runs once it's gone.
    func begin(ended: @escaping () -> Void) -> Bool {
        guard let w = Workbench.window?.window ?? NSApp.mainWindow, let sheet = window else { return false }
        w.beginSheet(sheet) { _ in ended() }
        return true
    }

    override func close() { if let w = window { w.sheetParent?.endSheet(w) } }
}
