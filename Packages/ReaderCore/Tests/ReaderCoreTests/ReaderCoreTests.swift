import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import ReaderCore

private let fixture = Bundle.module.url(forResource: "sample", withExtension: "djvu", subdirectory: "Fixtures")!

@Test func djvuOpensAndReportsPages() throws {
    let doc = try DjVuPageSource(url: fixture)
    #expect(doc.pageCount == 2)
    let size = doc.pageSize(at: 0)
    #expect(abs(size.width - 576) < 1)   // 1200 px at 150 dpi = 8 in = 576 pt
    #expect(abs(size.height - 768) < 1)
}

@Test func djvuRendersPixels() throws {
    let doc = try DjVuPageSource(url: fixture)
    let image = try doc.renderPage(at: 0, maxPixelSize: 800)
    #expect(max(image.width, image.height) == 800)
    // The text band should contain dark pixels; the page corner should be white.
    let gray = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
    gray.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let px = gray.data!.assumingMemoryBound(to: UInt8.self)
    #expect(px[0] > 200)
    let dark = (0..<(image.width * image.height)).filter { px[$0] < 100 }.count
    #expect(dark > 500)
}

@Test func djvuHiddenTextAndOutline() throws {
    let doc = try DjVuPageSource(url: fixture)
    let text = try #require(doc.embeddedText(at: 0))
    #expect(text.plainText == "Hello DjVu Reader")
    let hello = text.lines[0][0]
    #expect(abs(hello.rect.minX - 100.0 / 1200) < 0.001)
    #expect(abs(hello.rect.minY - (1 - 1360.0 / 1600)) < 0.001)
    #expect(doc.embeddedText(at: 1) == nil)
    #expect(doc.outline.map(\.title) == ["Chapter 1", "Chapter 2"])
    #expect(doc.outline.map(\.pageIndex) == [0, 1])
}

@Test func ocrRecognisesPageWithoutTextLayer() async throws {
    let doc = try DjVuPageSource(url: fixture)
    let cache = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let provider = TextProvider(source: doc, ocr: OCRService(languages: ["en-US"]), cacheRoot: cache)
    let text = try #require(try await provider.text(page: 1))
    #expect(text.origin == .ocr)
    #expect(text.plainText.localizedCaseInsensitiveContains("second page"))
    // Second instance reads it back from the disk cache.
    let again = await TextProvider(source: doc, cacheRoot: cache).availableText(page: 1)
    #expect(again == text)
}

@Test func pdfSourceRendersAndExtracts() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).pdf")
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
    let pdf = try PDFPageSource(url: url)
    #expect(pdf.pageCount == 1)
    let image = try pdf.renderPage(at: 0, maxPixelSize: 400)
    #expect(image.height == 400 && image.width == 300)
    #expect(pdf.embeddedText(at: 0) == nil)
}

@Test func promptIncludesSelectionAndContext() {
    let ctx = ReadingContext(documentTitle: "Book", pageIndex: 4, selection: "entropy", surroundingText: "page body")
    let msg = ReadingAssistant.firstMessage(question: "What is this?", context: ctx)
    #expect(msg.contains("current page 5"))
    #expect(msg.contains("<selection>\nentropy\n</selection>"))
    #expect(msg.hasSuffix("What is this?"))
}

@Test func appleFlattenKeepsHistory() {
    let flat = AppleOnDeviceProvider.flatten([
        ChatMessage(role: .user, content: "a"), ChatMessage(role: .assistant, content: "b"), ChatMessage(role: .user, content: "c"),
    ])
    #expect(flat.contains("User: a") && flat.contains("Assistant: b") && flat.hasSuffix("User: c"))
}

@Test func pdfRendersLargerThanPageSize() throws {
    // Regression: renders above the page's point size used to stay at 1x, centred in a white canvas.
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).pdf")
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(box)
    ctx.endPDFPage(); ctx.closePDF()
    let image = try PDFPageSource(url: url).renderPage(at: 0, maxPixelSize: 2000)
    #expect(image.height == 2000 && image.width == 1500)
    let gray = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
    gray.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let px = gray.data!.assumingMemoryBound(to: UInt8.self)
    #expect(px[5 * image.width + 5] < 50)   // near a corner: page content, not padding
}
