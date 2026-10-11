import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

private func label(_ location: Highlight.Location) -> String {
    switch location {
    case .pdf(let rects): "p. \((rects.first?.page ?? 0) + 1)"
    case .image(let page, _): "p. \(page + 1)"
    case .text(let chapter, _, _, _, _): "Chapter \(chapter + 1)"
    }
}

@Test func fingerprintIsStableAndContentBased() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let big = Data((0..<1_200_000).map { UInt8($0 % 253) })
    try big.write(to: dir.appending(path: "a.pdf"))
    try big.write(to: dir.appending(path: "renamed.pdf"))
    var changed = big; changed[1_100_000] ^= 0xFF          // differs only in the tail
    try changed.write(to: dir.appending(path: "c.pdf"))
    let a = try DocumentFingerprint.id(for: dir.appending(path: "a.pdf"))
    #expect(a.count == 20)
    #expect(a == (try DocumentFingerprint.id(for: dir.appending(path: "renamed.pdf"))))
    #expect(a != (try DocumentFingerprint.id(for: dir.appending(path: "c.pdf"))))
}

@Test func mergeUnionsAndHonoursDeletions() {
    let h1 = Highlight(text: "one", location: .text(chapter: 0, start: 10, end: 13, prefix: "", suffix: ""))
    let h2 = Highlight(text: "two", location: .text(chapter: 0, start: 2, end: 5, prefix: "", suffix: ""))
    let h3 = Highlight(text: "three", location: .image(page: 3, rects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)]))
    let iPad = BookHighlights(documentID: "x", title: "T", fileName: "t.epub", highlights: [h1, h3])
    var mac = BookHighlights(documentID: "x", title: "T", fileName: "t.epub", highlights: [h1, h2])
    mac.deleted = [h3.id]                                     // deleted elsewhere
    let merged = iPad.merged(with: mac)
    #expect(merged.highlights.map(\.text) == ["two", "one"])  // reading order: offset 2 before 10
    #expect(merged.deleted == [h3.id])
}

@Test func storeWritesJSONAndMarkdownAndMergesConcurrentEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = HighlightStore(root: root)
    let h1 = Highlight(text: "It is a truth universally acknowledged", color: .yellow,
                       location: .text(chapter: 1, start: 0, end: 39, prefix: "", suffix: ", that"))
    var book = BookHighlights(documentID: "abc", title: "Pride: and Prejudice", fileName: "Pride.epub", highlights: [h1])
    try await store.save(book, locationLabel: label)

    // Another device adds one; this device (stale copy) adds a different one. Both survive.
    let other = Highlight(text: "single man", color: .green, location: .text(chapter: 1, start: 50, end: 60, prefix: "", suffix: ""))
    try await store.save(BookHighlights(documentID: "abc", title: book.title, fileName: book.fileName, highlights: [h1, other]),
                         locationLabel: label)
    let mine = Highlight(text: "Mrs. Bennet", location: .text(chapter: 2, start: 5, end: 16, prefix: "", suffix: ""))
    book.highlights.append(mine)
    let saved = try await store.save(book, locationLabel: label)
    #expect(Set(saved.highlights.map(\.text)) == ["It is a truth universally acknowledged", "single man", "Mrs. Bennet"])

    let loaded = try #require(await store.load(documentID: "abc"))
    #expect(loaded.highlights.count == 3)
    let md = try String(contentsOf: root.appending(path: "Highlights/Pride- and Prejudice.md"), encoding: .utf8)
    #expect(md.hasPrefix("# Pride: and Prejudice"))
    #expect(md.contains("> It is a truth universally acknowledged\n\n— Chapter 2"))
    #expect(md.contains("· green"))

    // Deleting everything removes the Markdown but keeps the tombstones in JSON.
    var cleared = loaded
    cleared.deleted.formUnion(cleared.highlights.map(\.id))
    cleared.highlights = []
    let empty = try await store.save(cleared, locationLabel: label)
    #expect(empty.highlights.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Highlights/Pride- and Prejudice.md").path))
}

@Test func liveTextSelectionMapsToWordRects() {
    func w(_ t: String, _ x: Double, _ y: Double) -> PageText.Word { .init(text: t, rect: CGRect(x: x, y: y, width: 0.08, height: 0.02)) }
    let page = PageText(origin: .ocr, lines: [
        [w("The", 0.1, 0.1), w("second", 0.2, 0.1), w("law", 0.3, 0.1), w("of", 0.4, 0.1)],
        [w("thermodynamics", 0.1, 0.13), w("states,", 0.3, 0.13), w("that", 0.4, 0.13)],
    ])
    let rects = try! #require(page.rects(matching: "law of\nthermodynamics states"))
    #expect(rects.count == 2)                                // one rect per line
    #expect(abs(rects[0].minX - 0.3) < 1e-9 && abs(rects[0].maxX - 0.48) < 1e-9)
    #expect(abs(rects[1].minX - 0.1) < 1e-9 && abs(rects[1].maxX - 0.38) < 1e-9)
    // OCR disagreement on one word still matches; unrelated text doesn't.
    #expect(page.rects(matching: "law af thermodynamics") != nil)
    #expect(page.rects(matching: "completely different words here") == nil)
}
