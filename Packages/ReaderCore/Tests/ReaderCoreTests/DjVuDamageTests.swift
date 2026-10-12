import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

/// Some scans carry a truncated FGbz (foreground palette whose BZZ colour indices are cut off). Stock
/// DjVuLibre fails the whole page ("Unexpected End Of File") and the reader shows it blank; the patched
/// library ignores the palette and renders the page.
@Test func djvuPageWithTruncatedPaletteStillRenders() throws {
    let fixture = try Data(contentsOf: try #require(Bundle.module.url(forResource: "sample", withExtension: "djvu", subdirectory: "Fixtures")))
    let bytes = [UInt8](fixture)
    func be32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
    // First page FORM:DJVU inside the bundled document (offset from DIRM).
    let pageOffset = be32(4 + 4 + 4 + 4 + 4 + 4 + 1 + 2)        // AT&T FORM size DJVM DIRM size flags count → offsets[0]
    #expect(bytes[pageOffset..<pageOffset + 4].elementsEqual("FORM".utf8))
    let pageSize = be32(pageOffset + 4)
    var page = Array(bytes[pageOffset + 8..<pageOffset + 8 + pageSize])  // "DJVU" + chunks
    // Truncated palette: 2 colours, "1532 indices follow", then 7 bytes of BZZ data that end too soon.
    let fgbz: [UInt8] = [0x80, 0x00, 0x02, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x00, 0x05, 0xFC, 0xFF, 0xFF, 0x00, 0x01, 0x02, 0x03, 0x04]
    if page.count % 2 == 1 { page.append(0) }                     // chunks start at even offsets
    page += Array("FGbz".utf8) + withUnsafeBytes(of: UInt32(fgbz.count).bigEndian, Array.init) + fgbz + [0]   // pad to even
    let file = Array("AT&TFORM".utf8) + withUnsafeBytes(of: UInt32(page.count).bigEndian, Array.init) + page
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).djvu")
    try Data(file).write(to: url)

    let source = try DjVuPageSource(url: url)
    #expect(source.pageCount == 1)
    let image = try source.renderPage(at: 0, maxPixelSize: 300)
    #expect(image.width > 100)
}
