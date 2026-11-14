import AppKit
import PDFKit
import ReaderCore

/// File › Print… for a book window: PDFs through PDFKit, text (EPUB, web pages, PDF/DjVu viewed as text)
/// through the web view, DjVu and other page images one per sheet.
@MainActor
enum MacPrinting {
    static func print(_ model: ReaderModel) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        let operation: NSPrintOperation?
        if model.reflowable != nil {
            operation = model.webPrintOperation?()
        } else if let document = model.pdfDocument {
            operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true)
        } else {
            operation = NSPrintOperation(view: PageImagesPrintView(source: model.source, printInfo: info), printInfo: info)
        }
        guard let operation else { return }
        operation.jobTitle = model.book.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsPageRange, .showsCopies, .showsPaperSize, .showsOrientation, .showsPreview])
        if let window = NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

/// One sheet per page of a page source (DjVu, images), rendered when the sheet is printed.
private final class PageImagesPrintView: NSView {
    let source: PageSource

    init(source: PageSource, printInfo: NSPrintInfo) {
        self.source = source
        let sheet = printInfo.imageablePageBounds.size
        super.init(frame: NSRect(x: 0, y: 0, width: sheet.width, height: sheet.height * CGFloat(max(1, source.pageCount))))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var sheet: NSSize {
        NSPrintOperation.current?.printInfo.imageablePageBounds.size ?? NSSize(width: bounds.width, height: bounds.width * 1.41)
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, source.pageCount))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let size = sheet
        return NSRect(x: 0, y: CGFloat(page - 1) * size.height, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let page = NSPrintOperation.current?.currentPage, page >= 1, page <= source.pageCount,
              let context = NSGraphicsContext.current?.cgContext,
              let image = try? source.renderPage(at: page - 1, maxPixelSize: 3000) else { return }
        let slot = rectForPage(page)
        let scale = min(slot.width / CGFloat(image.width), slot.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(x: slot.midX - size.width / 2, y: slot.minY, width: size.width, height: size.height)
        // The view is flipped; draw the image upright.
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }
}
