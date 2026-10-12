import Foundation
import Testing
@testable import ReaderCore

/// sample.azw3 is calibre's conversion of sample.fb2 (Cyrillic, two chapters, a footnote, a cover image).
@Test func azw3RebuildsPartsContentsAndLinks() throws {
    let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "azw3", subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: "sample", withExtension: "azw3"))
    let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).azw3")
    try FileManager.default.copyItem(at: url, to: copy)
    let book = try #require(try DocumentOpener.open(copy) as? AZW3Source)
    print("AZW3 title=\(book.title ?? "-") chapters=\(book.chapterTitles) outline=\(book.outline.map(\.title))")
    #expect(book.title == "Тепло и порядок")
    #expect(book.pageCount >= 2)
    let all = (0..<book.pageCount).map { (try? String(contentsOf: book.chapterURL(at: $0), encoding: .utf8)) ?? "" }.joined()
    #expect(all.contains("href=\"part0005.html#n1\""))             // footnote link resolved to its anchor
    #expect(all.contains("id=\"n1\""))
    #expect(!all.contains("kindle:"))                                   // every kindle: reference resolved
    #expect(!all.contains(" aid=\""))
    #expect(book.outline.contains { $0.title.contains("Глава первая") })
    let text = (0..<book.pageCount).compactMap { book.embeddedText(at: $0)?.plainText }.joined(separator: " ")
    #expect(text.contains("Больцман") && text.contains("Энтропия не убывает"))
    #expect((try? book.renderPage(at: 0, maxPixelSize: 64)) != nil)        // cover
}

/// Manual probe: AZW3_PROBE=/path/book.azw3 swift test --filter probeRealAZW3
@Test(.enabled(if: ProcessInfo.processInfo.environment["AZW3_PROBE"] != nil))
func probeRealAZW3() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AZW3_PROBE"]!)
    let start = Date()
    let book = try AZW3Source(url: url)
    print("PROBE parts=\(book.pageCount) time=\(String(format: "%.2f", Date().timeIntervalSince(start)))s title=\(book.title ?? "-")")
    print("PROBE titles: \(book.chapterTitles.prefix(10).joined(separator: " | "))")
    print("PROBE outline: \(book.outline.count) top-level, first: \(book.outline.prefix(5).map(\.title))")
    let all = (0..<book.pageCount).map { (try? String(contentsOf: book.chapterURL(at: $0), encoding: .utf8)) ?? "" }.joined()
    print("PROBE broken-up-paths=\(all.components(separatedBy: "\"../img/").count - 1)")
    print("PROBE kindle-left=\(all.components(separatedBy: "kindle:").count - 1) imgs=\(all.components(separatedBy: "<img").count - 1) links=\(all.components(separatedBy: "href=\"part").count - 1)")
    print("PROBE text: \(book.embeddedText(at: min(3, book.pageCount - 1))?.plainText.prefix(200) ?? "")")
}
