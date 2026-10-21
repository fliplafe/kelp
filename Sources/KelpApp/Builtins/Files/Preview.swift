import AppKit
import PDFKit
import Quartz

/// Read-only previews for files the editor shouldn't open: PDFs via PDFKit, everything else Quick Look can show.
@MainActor
enum Preview {
    static let pdf: Set<String> = ["pdf"]
    static let quickLook: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg", "ico",
        "mov", "mp4", "mp3", "wav", "key", "pages", "numbers", "docx", "xlsx", "pptx", "zip"]

    static func canPreview(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased(); return pdf.contains(e) || quickLook.contains(e)
    }

    static func view(for url: URL) -> NSView {
        if pdf.contains(url.pathExtension.lowercased()), let doc = PDFDocument(url: url) {
            let v = PDFView(); v.document = doc; v.autoScales = true; v.displayMode = .singlePageContinuous; return v
        }
        let q = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        q.previewItem = url as NSURL
        q.shouldCloseWithWindow = false
        return q
    }
}
