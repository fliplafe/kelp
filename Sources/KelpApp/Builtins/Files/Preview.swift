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
            let v = PDFView(); v.document = doc; v.autoScales = true; v.displayMode = .singlePageContinuous
            v.delegate = PDFLinks.shared   // without a delegate PDFKit opens any link with its app
            return v
        }
        let q = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        q.previewItem = url as NSURL
        q.shouldCloseWithWindow = false
        return q
    }
}

/// Links clicked in a PDF go by the preview's rules (`PreviewLinks.target`): a repo's PDF can link to an app it ships
/// or to another app's scheme, and PDFKit on its own would open either.
@MainActor
final class PDFLinks: NSObject, PDFViewDelegate {
    static let shared = PDFLinks()
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) { PreviewLinks.open(url) }
}
