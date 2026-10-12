import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

@Test func newerNoteEditWinsWhenDevicesMerge() {
    let base = Highlight(text: "entropy", created: Date(timeIntervalSince1970: 100),
                         location: .image(page: 2, rects: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.02)]))
    var onIPad = base
    onIPad.note = "old thought"
    onIPad.modified = Date(timeIntervalSince1970: 200)
    var onMac = base
    onMac.note = "newer thought"
    onMac.modified = Date(timeIntervalSince1970: 300)
    let a = BookHighlights(documentID: "d", title: "T", fileName: "t.pdf", highlights: [onIPad])
    let b = BookHighlights(documentID: "d", title: "T", fileName: "t.pdf", highlights: [onMac])
    #expect(a.merged(with: b).highlights.first?.note == "newer thought")
    #expect(b.merged(with: a).highlights.first?.note == "newer thought")

    // Same for page notes on bookmarks.
    var page = Bookmark(page: 4, label: "p. 5", snippet: "Chapter two", created: Date(timeIntervalSince1970: 100))
    let plain = page
    page.note = "see figure 3"
    page.modified = Date(timeIntervalSince1970: 150)
    let withNote = BookHighlights(documentID: "d", title: "T", fileName: "t.pdf", bookmarks: [page])
    let without = BookHighlights(documentID: "d", title: "T", fileName: "t.pdf", bookmarks: [plain])
    #expect(without.merged(with: withNote).bookmarks.first?.note == "see figure 3")
}

@Test func annotationsAppearInMarkdownAndDrawingsRoundTrip() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = HighlightStore(root: root)
    let drawing = UUID()
    let highlight = Highlight(text: "softmax", note: "turns scores\ninto probabilities", drawingID: drawing,
                              modified: Date(), location: .pdf(rects: [.init(page: 118, rect: .zero)]))
    let pageNote = Bookmark(page: 3, label: "p. 4", snippet: "Attention is all you need", note: "Key page", modified: Date())
    let plainMark = Bookmark(page: 9, label: "p. 10", snippet: "Results")
    let book = BookHighlights(documentID: "doc", title: "Paper", fileName: "paper.pdf",
                              highlights: [highlight], bookmarks: [pageNote, plainMark])
    try await store.save(book) { _ in "p. 119" }

    let md = try String(contentsOf: root.appending(path: "Highlights/Paper.md"), encoding: .utf8)
    #expect(md.contains("\t- softmax @location(p. 119)"))
    #expect(md.contains("@drawing(Drawings/\(drawing.uuidString).png)"))
    #expect(md.contains("\t\tturns scores\n\t\tinto probabilities"))
    #expect(md.contains("\t- Page note: Attention is all you need @pagenote @location(p. 4)"))
    #expect(md.contains("\t\tKey page"))
    #expect(md.contains("\t- Bookmark: Results @bookmark"))

    try await store.saveDrawing(id: drawing, data: Data([1, 2, 3]), png: Data([9]))
    #expect(await store.loadDrawing(id: drawing) == Data([1, 2, 3]))
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Highlights/Drawings/\(drawing.uuidString).png").path))
    await store.deleteDrawing(id: drawing)
    #expect(await store.loadDrawing(id: drawing) == nil)

    // Files written before annotations existed still load.
    let old = #"{"id":"\#(UUID().uuidString)","page":1,"progress":0,"label":"p. 2","snippet":"x","created":"2026-01-01T00:00:00Z"}"#
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let legacy = try decoder.decode(Bookmark.self, from: Data(old.utf8))
    #expect(legacy.note == nil && !legacy.hasAnnotation)
}
