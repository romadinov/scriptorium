import CoreGraphics
import Foundation
import PDFKit

/// PDF document. The app displays PDFs with `PDFView`; this source is used for
/// thumbnails, OCR of scanned pages and extracting text for LLM context.
public final class PDFPageSource: PageSource, @unchecked Sendable {
    public let url: URL
    public let document: PDFDocument
    public private(set) lazy var outline: [OutlineItem] = document.outlineRoot.map { children(of: $0) } ?? []
    private let lock = NSLock()

    public init(url: URL) throws {
        guard let document = PDFDocument(url: url) else { throw DocumentError.cannotOpen(url) }
        self.url = url
        self.document = document
    }

    public init(document: PDFDocument, url: URL) {
        self.url = url
        self.document = document
    }

    public var pageCount: Int { document.pageCount }

    public func pageSize(at index: Int) -> CGSize {
        guard let page = document.page(at: index) else { return .zero }
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    public func renderPage(at index: Int, maxPixelSize: Int) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        guard let page = document.page(at: index) else { throw DocumentError.renderFailed(page: index) }
        let size = pageSize(at: index)
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
        guard let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        // PDFView handles selection geometry itself, so only the text is needed here.
        let lines = text.components(separatedBy: .newlines).map { [PageText.Word(text: $0, rect: .zero)] }
        return PageText(origin: .embedded, lines: lines)
    }

    private func children(of node: PDFOutline) -> [OutlineItem] {
        (0..<node.numberOfChildren).compactMap { node.child(at: $0) }.map { child in
            let pageIndex = child.destination?.page.map { document.index(for: $0) }
            return OutlineItem(title: child.label ?? "—", pageIndex: pageIndex, children: children(of: child))
        }
    }
}
