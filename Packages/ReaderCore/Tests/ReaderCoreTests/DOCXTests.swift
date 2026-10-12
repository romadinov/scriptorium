import Foundation
import Testing
import ZIPFoundation
@testable import ReaderCore

/// A small but realistic .docx: styles with localized ids, runs split mid-word, a nested list,
/// a table, links, a bookmark, a footnote and an image.
private func makeDOCX() throws -> URL {
    let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture""#
    func p(_ text: String, style: String? = nil) -> String {
        let pPr = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        return "<w:p>\(pPr)<w:r><w:t xml:space=\"preserve\">\(text)</w:t></w:r></w:p>"
    }
    func li(_ text: String, num: Int, level: Int) -> String {
        "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(num)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
    }
    let document = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document \(w)><w:body>
    \(p("Тепловые машины", style: "1"))
    <w:p><w:r><w:t>Entr</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>opy</w:t></w:r><w:r><w:t xml:space="preserve"> never decreases.</w:t></w:r><w:r><w:footnoteReference w:id="2"/></w:r></w:p>
    <w:p><w:r><w:rPr><w:vanish/></w:rPr><w:t>HIDDEN</w:t></w:r><w:r><w:t>Visible</w:t></w:r></w:p>
    \(li("First", num: 1, level: 0))
    \(li("Nested", num: 1, level: 1))
    \(li("Second", num: 1, level: 0))
    \(li("Step one", num: 2, level: 0))
    <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Cell B</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
    <w:p><w:hyperlink r:id="rIdLink"><w:r><w:t>Apple</w:t></w:r></w:hyperlink><w:r><w:t xml:space="preserve"> and </w:t></w:r><w:hyperlink w:anchor="target"><w:r><w:t>see below</w:t></w:r></w:hyperlink></w:p>
    <w:p><w:r><w:drawing><wp:inline><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rIdImg"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
    \(p("Subsection", style: "2"))
    \(p("Second chapter", style: "1"))
    <w:p><w:bookmarkStart w:id="0" w:name="target"/><w:r><w:t>Target paragraph.</w:t></w:r><w:bookmarkEnd w:id="0"/></w:p>
    <w:sectPr/>
    </w:body></w:document>
    """
    let styles = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:styles \(w)>
    <w:style w:type="paragraph" w:styleId="1"><w:name w:val="heading 1"/></w:style>
    <w:style w:type="paragraph" w:styleId="2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/></w:style>
    </w:styles>
    """
    let numbering = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:numbering \(w)>
    <w:abstractNum w:abstractNumId="10"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl><w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
    <w:abstractNum w:abstractNumId="11"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
    <w:num w:numId="1"><w:abstractNumId w:val="10"/></w:num>
    <w:num w:numId="2"><w:abstractNumId w:val="11"/></w:num>
    </w:numbering>
    """
    let footnotes = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:footnotes \(w)>
    <w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>
    <w:footnote w:id="2"><w:p><w:r><w:t>Second law of thermodynamics.</w:t></w:r></w:p></w:footnote>
    </w:footnotes>
    """
    let rels = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rIdLink" Type="hyperlink" Target="https://www.apple.com/" TargetMode="External"/>
    <Relationship Id="rIdImg" Type="image" Target="media/image1.png"/>
    </Relationships>
    """
    let core = #"<?xml version="1.0"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Heat Engines</dc:title></cp:coreProperties>"#
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).docx")
    let archive = try Archive(url: url, accessMode: .create)
    for (path, data) in [("word/document.xml", Data(document.utf8)), ("word/styles.xml", Data(styles.utf8)),
                         ("word/numbering.xml", Data(numbering.utf8)), ("word/footnotes.xml", Data(footnotes.utf8)),
                         ("word/_rels/document.xml.rels", Data(rels.utf8)), ("docProps/core.xml", Data(core.utf8)),
                         ("word/media/image1.png", png)] {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
    return url
}

@Test func docxConvertsToChaptersWithFormatting() throws {
    let url = try makeDOCX()
    let book = try #require(try DocumentOpener.open(url) as? DOCXSource)
    #expect(book.title == "Heat Engines")
    #expect(book.chapterTitles == ["Тепловые машины", "Second chapter", "Notes"])
    #expect(book.outline.map(\.title) == ["Тепловые машины", "Second chapter", "Notes"])
    #expect(book.outline.first?.children.map(\.title) == ["Subsection"])

    let first = try String(contentsOf: book.chapterURL(at: 0), encoding: .utf8)
    #expect(first.contains("<h1>Тепловые машины</h1>"))
    #expect(first.contains("Entr<strong>opy</strong> never decreases."))
    #expect(first.contains("<sup><a class=\"note\" href=\"notes.html#fn2\">2</a></sup>"))
    #expect(!first.contains("HIDDEN") && first.contains("Visible"))
    #expect(first.contains("<ul><li>First<ul><li>Nested</li></ul></li><li>Second</li></ul><ol><li>Step one</li></ol>"))
    #expect(first.contains("<table><tr><td><p>Cell A</p></td><td><p>Cell B</p></td></tr></table>"))
    #expect(first.contains("<a href=\"https://www.apple.com/\">Apple</a>"))
    #expect(first.contains("<a href=\"ch1.html#target\">see below</a>"))
    #expect(first.contains("<img src=\"img/0-image1.png\""))
    #expect(first.contains("<h2>Subsection</h2>"))

    let second = try String(contentsOf: book.chapterURL(at: 1), encoding: .utf8)
    #expect(second.contains("<a id=\"target\"></a>Target paragraph."))
    let notes = try String(contentsOf: book.chapterURL(at: 2), encoding: .utf8)
    #expect(notes.contains("<section id=\"fn2\" class=\"note\"><p>Second law of thermodynamics.</p></section>"))

    // Text for the assistant/search, and the image doubles as the cover.
    #expect(book.embeddedText(at: 0)?.plainText.contains("Entropy never decreases.") == true)
    #expect((try? book.renderPage(at: 0, maxPixelSize: 64)) != nil)
}

@Test func convertedDocSplitsAtTopHeadings() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).doc")
    try Data("x".utf8).write(to: url)
    #expect(throws: DocumentError.self) { try DOCSource(url: url) }       // not converted yet
    try DOCSource.saveConverted(html: """
    <html><head><style>p{margin:0}</style></head><body><div class="s1"><style>.s2{font-weight:bold}</style>
    <h1 class="x">Heat and <b>Order</b></h1><p>Entropy.</p><h1>Second chapter</h1><p>Энтропия.</p></body></html>
    """, for: url)
    let book = try #require(try DocumentOpener.open(url) as? DOCSource)
    // Only a wrapper and a style before the first heading: no empty "Beginning" chapter.
    #expect(book.chapterTitles == ["Heat and Order", "Second chapter"])
    #expect(book.outline.map(\.title) == ["Heat and Order", "Second chapter"])
    let first = try String(contentsOf: book.chapterURL(at: 0), encoding: .utf8)
    #expect(first.contains("<style>p{margin:0}</style><style>.s2{font-weight:bold}</style></head>"))
    #expect(first.contains("Entropy.") && !first.contains("Энтропия"))
    #expect(book.embeddedText(at: 1)?.plainText.contains("Энтропия.") == true)
}

@Test func docxHeadingsInferredFromFormattingWhenUnstyled() throws {
    func run(_ text: String, size: Int, bold: Bool = false) -> String {
        "<w:r><w:rPr>\(bold ? "<w:b/>" : "")<w:sz w:val=\"\(size)\"/></w:rPr><w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
    }
    let body = """
    <w:p>\(run("Heat and Order", size: 48, bold: true))</w:p>
    <w:p>\(run("The second law of thermodynamics says that entropy never decreases, and much more body text here.", size: 24))</w:p>
    <w:p>\(run("Boltzmann", size: 36, bold: true))</w:p>
    <w:p>\(run("Ludwig Boltzmann expressed this idea in the formula S = k log W, with plenty of body text.", size: 24))</w:p>
    <w:p>\(run("Second chapter", size: 48, bold: true))</w:p>
    <w:p>\(run("Энтропия — мера необратимого рассеивания энергии.", size: 24))</w:p>
    """
    let xml = #"<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"# + body + "</w:body></w:document>"
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).docx")
    let archive = try Archive(url: url, accessMode: .create)
    let data = Data(xml.utf8)
    try archive.addEntry(with: "word/document.xml", type: .file, uncompressedSize: Int64(data.count)) { position, size in
        data.subdata(in: Int(position)..<Int(position) + size)
    }
    let book = try DOCXSource(url: url)
    #expect(book.chapterTitles == ["Heat and Order", "Second chapter"])
    #expect(book.outline.first?.children.map(\.title) == ["Boltzmann"])
}
