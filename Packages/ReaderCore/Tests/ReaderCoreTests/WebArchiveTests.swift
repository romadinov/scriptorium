import Foundation
import Testing
@testable import ReaderCore

/// Builds a .webarchive the way Safari does: a binary plist with a main resource and subresources.
private func makeArchive(html: String, encoding: String = "UTF-8", htmlData: Data? = nil) throws -> URL {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    let big = png + Data(count: 9_000)   // "photo" large enough to become the cover
    let css = "body { background: url('../img/bg.png') } h1 { font-family: Serif }"
    let archive: [String: Any] = [
        "WebMainResource": [
            "WebResourceURL": "https://example.com/articles/entropy.html#top",
            "WebResourceMIMEType": "text/html",
            "WebResourceTextEncodingName": encoding,
            "WebResourceData": htmlData ?? Data(html.utf8),
            "WebResourceFrameName": "",
        ],
        "WebSubresources": [
            ["WebResourceURL": "https://example.com/css/site.css", "WebResourceMIMEType": "text/css", "WebResourceData": Data(css.utf8)],
            ["WebResourceURL": "https://example.com/img/bg.png", "WebResourceMIMEType": "image/png", "WebResourceData": png],
            ["WebResourceURL": "https://cdn.example.com/photo.jpg", "WebResourceMIMEType": "image/jpeg", "WebResourceData": big],
            ["WebResourceURL": "https://cdn.example.com/photo@2x.jpg", "WebResourceMIMEType": "image/jpeg", "WebResourceData": big],
        ],
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString.prefix(8)) Entropy.webarchive")
    try data.write(to: url)
    return url
}

@Test func webArchiveConvertsToLocalReflowableBook() throws {
    let html = """
    <html><head><title>Entropy &amp; Order</title><link rel="stylesheet" href="../css/site.css">
    <script>document.write('tracking')</script></head>
    <body onload="track()"><h1>Entropy</h1>
    <p>Disorder <a href="#notes">grows</a>.</p>
    <img src="//cdn.example.com/photo.jpg" srcset="https://cdn.example.com/photo.jpg 1x, https://cdn.example.com/photo@2x.jpg 2x">
    <img src="https://missing.example.com/x.png"></body></html>
    """
    let url = try makeArchive(html: html)
    let book = try #require(try DocumentOpener.open(url) as? WebArchiveSource)
    #expect(book.title == "Entropy & Order")
    #expect(book.pageCount == 1)
    #expect(book.chapterTitles == ["Entropy & Order"])

    let page = try String(contentsOf: book.chapterURL(at: 0), encoding: .utf8)
    #expect(!page.contains("<script") && !page.contains("onload="))
    #expect(page.contains(#"href="res/0.css""#))                              // relative ../css resolved
    #expect(page.contains(#"src="res/2.jpg""#))                               // protocol-relative //cdn
    #expect(page.contains(#"srcset="res/2.jpg 1x, res/3.jpg 2x""#))
    #expect(page.contains(##"href="#notes""##))                                 // in-page anchor untouched
    #expect(page.contains("https://missing.example.com/x.png"))               // not archived → left as is
    let css = try String(contentsOf: book.contentRoot.appending(path: "res/0.css"), encoding: .utf8)
    #expect(css.contains(#"url("1.png")"#))                                   // sibling inside res/

    #expect(book.embeddedText(at: 0)?.plainText.contains("Disorder grows.") == true)
    #expect(try book.renderPage(at: 0, maxPixelSize: 100).width >= 1)         // cover from the photo
    // Re-opening uses the converted folder.
    #expect((try WebArchiveSource(url: url)).title == "Entropy & Order")
}

@Test func webArchiveHonoursDeclaredEncoding() throws {
    let html = "<html><head><title>Энтропия</title></head><body><p>Мера беспорядка</p></body></html>"
    let data = html.data(using: .windowsCP1251)!
    let book = try WebArchiveSource(url: try makeArchive(html: html, encoding: "windows-1251", htmlData: data))
    #expect(book.title == "Энтропия")
    #expect(book.embeddedText(at: 0)?.plainText == "Мера беспорядка")
}
