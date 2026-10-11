import Foundation
import Testing
@testable import ReaderCore

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
}

/// Each test works on a copy with a unique name so Caches extraction is fresh.
private func freshCopy(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let target = dir.appending(path: "\(UUID().uuidString.prefix(8))-\(name)")
    try FileManager.default.copyItem(at: fixture(name), to: target)
    return target
}

@Test func epub3SpineNavCoverAndText() throws {
    let book = try #require(try DocumentOpener.open(try freshCopy("sample3.epub")) as? EPUBSource)
    #expect(book.title == "Heat and Order")
    #expect(book.pageCount == 2)
    #expect(book.chapterTitles == ["Chapter One", "Chapter Two"])
    #expect(book.outline.map(\.title) == ["Chapter One", "Chapter Two"])
    #expect(book.outline[0].children.first?.title == "Entropy")
    #expect(book.outline.map(\.pageIndex) == [0, 1])           // "ch%202.xhtml" resolves to "ch 2.xhtml"
    let text = try #require(book.embeddedText(at: 0)).plainText
    #expect(text == "Chapter One\nHeat flows from hot to cold.\nEntropy never decreases.")
    #expect(FileManager.default.fileExists(atPath: book.chapterURL(at: 1).path))
    let cover = try book.renderPage(at: 0, maxPixelSize: 100)
    #expect(cover.width >= 1)
}

@Test func epub2FallsBackToNCX() throws {
    let book = try #require(try DocumentOpener.open(try freshCopy("sample2.epub")) as? EPUBSource)
    #expect(book.outline.map(\.title) == ["Only Chapter"])
    #expect(book.outline.first?.pageIndex == 0)
    #expect(throws: DocumentError.self) { try book.renderPage(at: 0, maxPixelSize: 100) }   // no cover
}

@Test(arguments: ["sample.fb2", "sample.fb2.zip"])
func fb2ConvertsSectionsNotesAndCover(name: String) throws {
    let url = try freshCopy(name)
    let book = try #require(try DocumentOpener.open(url) as? FB2Source)
    #expect(book.title == "Тепло и порядок")                    // windows-1251 decoded
    #expect(book.chapterTitles == ["Тепло и порядок", "Глава первая", "Глава вторая", "Примечания"])
    #expect(book.outline.map(\.title) == ["Глава первая", "Глава вторая", "Примечания"])
    #expect(book.outline[0].children.map(\.title) == ["Больцман"])
    let ch1 = try #require(book.embeddedText(at: 1)).plainText
    #expect(ch1.contains("Энтропия не убывает"))
    #expect(ch1.contains("S = k log W"))
    let html = try String(contentsOf: book.chapterURL(at: 2), encoding: .utf8)
    #expect(html.contains("Строка один<br/>Строка два"))
    #expect(html.contains("<img src=\"img/cover.png.png\" alt=\"\"/>"))
    #expect(try book.renderPage(at: 0, maxPixelSize: 50).width >= 1)

    // Second open uses the cached manifest and gives the same structure.
    let again = try #require(try DocumentOpener.open(url) as? FB2Source)
    #expect(again.chapterTitles == book.chapterTitles)
    #expect(again.outline.map(\.title) == book.outline.map(\.title))
}

@Test func openerRecognisesFormats() {
    for name in ["a.pdf", "b.DJVU", "c.epub", "d.fb2", "e.fb2.zip"] {
        #expect(DocumentOpener.canOpen(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
    }
    #expect(!DocumentOpener.canOpen(URL(fileURLWithPath: "/x/photos.zip")))
}

