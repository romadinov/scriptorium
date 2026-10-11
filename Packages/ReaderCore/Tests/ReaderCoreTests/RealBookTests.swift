import Foundation
import Testing
@testable import ReaderCore

/// Point READER_REAL_BOOK at any EPUB/FB2 to smoke-test parsing of a real-world file.
@Test(.enabled(if: ProcessInfo.processInfo.environment["READER_REAL_BOOK"] != nil))
func realBookSmokeTest() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["READER_REAL_BOOK"]!)
    let start = Date()
    let book = try #require(try DocumentOpener.open(url) as? ReflowableSource)
    print("opened in \(String(format: "%.2f", Date().timeIntervalSince(start)))s: \(book.pageCount) chapters, \(book.outline.count) TOC entries")
    print("TOC:", book.outline.prefix(6).map { "\($0.title) → \($0.pageIndex.map(String.init) ?? "nil")" })
    print("titles:", book.chapterTitles.prefix(6))
    let cover = try? book.renderPage(at: 0, maxPixelSize: 480)
    print("cover:", cover.map { "\($0.width)x\($0.height)" } ?? "none")
    let withText = (0..<book.pageCount).filter { book.embeddedText(at: $0) != nil }.count
    print("chapters with text: \(withText)/\(book.pageCount)")
    if let sample = (0..<book.pageCount).lazy.compactMap({ book.embeddedText(at: $0) }).dropFirst(3).first {
        print("sample:", sample.plainText.prefix(300))
    }
    #expect(book.pageCount > 0 && withText > book.pageCount / 2)
}
