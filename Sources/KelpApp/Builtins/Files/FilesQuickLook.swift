import AppKit
import Quartz

/// Quick Look (Space) for the tree's selection.
extension FilesPanel: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    @objc func togglePreview() {
        guard let p = QLPreviewPanel.shared() else { return }
        if p.isVisible { p.orderOut(nil); return }
        p.makeKeyAndOrderFront(nil)
        if p.dataSource == nil { p.dataSource = self; p.delegate = self; p.reloadData() }   // no key window's chain led here
        if ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] != nil {   // the panel is its own window, not in the PNG
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { print("QUICKLOOK", p.isVisible, p.currentPreviewItem?.previewItemURL?.lastPathComponent ?? "-") }
        }
    }
    private var previewURL: URL? {
        (outline.item(atRow: outline.selectedRow) as? FileNode).map { URL(fileURLWithPath: root).appendingPathComponent($0.path) }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    // QuickLook asks the responder chain on the main thread; its informal protocol isn't annotated.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { panel.dataSource = self; panel.delegate = self } }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { panel.dataSource = nil; panel.delegate = nil } }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURL as NSURL? }
    /// ↑↓ in the preview walk the tree, like Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [125, 126].contains(event.keyCode) else { return false }
        outline.keyDown(with: event); return true
    }
}
