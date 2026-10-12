import Foundation
import Testing
@testable import ReaderCore

/// Manual probe: DOCX_PROBE=/path/to/file.docx swift test --filter probeRealDOCX
@Test(.enabled(if: ProcessInfo.processInfo.environment["DOCX_PROBE"] != nil))
func probeRealDOCX() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOCX_PROBE"]!)
    let start = Date()
    let book = try DOCXSource(url: url)
    print("PROBE chapters=\(book.pageCount) time=\(String(format: "%.2f", Date().timeIntervalSince(start)))s title=\(book.title ?? "-")")
    print("PROBE titles: \(book.chapterTitles.prefix(12).joined(separator: " | "))")
    let html = try String(contentsOf: book.chapterURL(at: min(1, book.pageCount - 1)), encoding: .utf8)
    print("PROBE html bytes=\(html.utf8.count) imgs=\(html.components(separatedBy: "<img").count - 1) p=\(html.components(separatedBy: "<p").count - 1)")
    print("PROBE text: \(book.embeddedText(at: min(1, book.pageCount - 1))?.plainText.prefix(300) ?? "")")
}
