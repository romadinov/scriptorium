import CoreGraphics
import Foundation
import PDFKit

/// PDF document. The app displays PDFs with `PDFView`; this source is used for
/// thumbnails, OCR of scanned pages and extracting text for LLM context.
///
/// PDFKit documents are not thread-safe, and the on-screen `PDFView` draws `document` on the main
/// thread. Background work (rendering for OCR/thumbnails, text extraction) therefore uses its own
/// separate instance, `worker`, so the two never touch the same object concurrently.
public final class PDFPageSource: PageSource, @unchecked Sendable {
    public let url: URL
    /// For the UI (PDFView, outline, annotations) — main thread only.
    public let document: PDFDocument
    /// Private copy for background rendering and text extraction, always used under `lock`.
    private let worker: PDFDocument
    public private(set) lazy var outline: [OutlineItem] = document.outlineRoot.map { children(of: $0) } ?? []
    private let lock = NSRecursiveLock()

    public init(url: URL) throws {
        guard let document = PDFDocument(url: url), let worker = PDFDocument(url: url) else {
            throw DocumentError.cannotOpen(url)
        }
        self.url = url
        self.document = document
        self.worker = worker
    }

    public var pageCount: Int { lock.withLock { worker.pageCount } }

    public func pageSize(at index: Int) -> CGSize {
        lock.lock()
        defer { lock.unlock() }
        guard let page = worker.page(at: index) else { return .zero }
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    public func renderPage(at index: Int, maxPixelSize: Int) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        guard let page = worker.page(at: index) else { throw DocumentError.renderFailed(page: index) }
        let box = page.bounds(for: .cropBox)
        let size = page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let scale = Double(maxPixelSize) / max(size.width, size.height)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        // `thumbnail` scales up as well as down and applies page rotation
        // (CGPDFPage.getDrawingTransform never scales up, which shrank large renders).
        #if canImport(UIKit)
        let image = page.thumbnail(of: target, for: .cropBox).cgImage
        #else
        let image = page.thumbnail(of: target, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
        guard let image else { throw DocumentError.renderFailed(page: index) }
        return image
    }

    public func embeddedText(at index: Int) -> PageText? {
        lock.lock()
        defer { lock.unlock() }
        guard let text = worker.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        // PDFView handles selection geometry itself, so only the text is needed here.
        let lines = text.components(separatedBy: .newlines).map { [PageText.Word(text: $0, rect: .zero)] }
        return PageText(origin: .embedded, lines: lines)
    }

    /// The page's text lines with where they are (normalised 0...1, origin top-left), straight from the PDF.
    public func textLines(at index: Int) -> [(text: String, rect: CGRect)] {
        lock.lock()
        defer { lock.unlock() }
        guard let page = worker.page(at: index) else { return [] }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0, let all = page.selection(for: box) else { return [] }
        return all.selectionsByLine().compactMap { line in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let r = line.bounds(for: page)
            return (text, CGRect(x: (r.minX - box.minX) / box.width, y: (box.maxY - r.maxY) / box.height,
                                 width: r.width / box.width, height: r.height / box.height))
        }
    }

    private func children(of node: PDFOutline) -> [OutlineItem] {
        (0..<node.numberOfChildren).compactMap { node.child(at: $0) }.map { child in
            let pageIndex = child.destination?.page.map { document.index(for: $0) }
            return OutlineItem(title: child.label ?? "—", pageIndex: pageIndex, children: children(of: child))
        }
    }
}
