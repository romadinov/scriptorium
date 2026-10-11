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
    #expect(md.hasPrefix("Pride – and Prejudice:\n"))                       // TaskPaper project (":" is reserved)
    #expect(md.contains("\t- It is a truth universally acknowledged @location(Chapter 2) @date("))
    #expect(md.contains("@color(green)"))

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

@Test func readLaterAppendsTaskPaperAndKeepsUserEdits() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/Read Later.md")
    let list = ReadLaterList(file: file)
    #expect(try list.add(.init(title: "Entropy (Wikipedia)", url: "https://en.wikipedia.org/wiki/Entropy",
                               source: "Physics notes, p. 3", added: Date(timeIntervalSince1970: 1_790_000_000))))
    #expect(try !list.add(.init(title: "dup", url: "https://en.wikipedia.org/wiki/Entropy")))   // already listed

    // The user marks it done in TaskPaper and adds their own project; the app must keep both.
    var text = try String(contentsOf: file, encoding: .utf8)
    text = text.replacingOccurrences(of: "@added(", with: "@done @added(")
    text += "\nMy stuff:\n\t- something else\n"
    try text.write(to: file, atomically: true, encoding: .utf8)

    #expect(try list.add(.init(title: "Boltzmann (Britannica)", url: "https://www.britannica.com/biography/Ludwig-Boltzmann")))
    let final = try String(contentsOf: file, encoding: .utf8)
    #expect(final.hasPrefix("Read Later:\n\t- Entropy [Wikipedia] @url(https://en.wikipedia.org/wiki/Entropy)") == false)
    #expect(final.contains("\t- Entropy (Wikipedia) @url(https://en.wikipedia.org/wiki/Entropy) @from(Physics notes, p. 3) @done @added(2026-"))
    #expect(final.contains("My stuff:\n\t- something else"))
    // New item lands inside the Read Later project, before "My stuff".
    let readLaterBlock = final.components(separatedBy: "My stuff:")[0]
    #expect(readLaterBlock.contains("Boltzmann (Britannica)"))
    let entries = list.entries()
    #expect(entries.map(\.title) == ["Entropy (Wikipedia)", "Boltzmann (Britannica)"])
    #expect(entries.map(\.done) == [true, false])
}

@Test func bookmarksMergeSyncAndLoadFromOlderFiles() async throws {
    // A file written before bookmarks existed still decodes.
    let legacy = #"{"documentID":"x","title":"T","fileName":"t.pdf","highlights":[],"deleted":[],"updated":"2026-10-01T00:00:00Z"}"#
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(BookHighlights.self, from: Data(legacy.utf8)).bookmarks.isEmpty)

    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = HighlightStore(root: root)
    let b12 = Bookmark(page: 11, label: "p. 12", snippet: "Chapter Three")
    let b3 = Bookmark(page: 2, progress: 0.5, label: "p. 3", snippet: "Prologue")
    try await store.save(BookHighlights(documentID: "doc", title: "Book", fileName: "b.pdf", path: "Physics/b.pdf", bookmarks: [b12]),
                         locationLabel: label)
    // Another device: adds one, deletes nothing.
    let merged = try await store.save(BookHighlights(documentID: "doc", title: "Book", fileName: "b.pdf", bookmarks: [b3]),
                                      locationLabel: label)
    #expect(merged.bookmarks.map(\.label) == ["p. 3", "p. 12"])      // sorted by position
    #expect(merged.path == "Physics/b.pdf")
    let md = try String(contentsOf: root.appending(path: "Highlights/Book.md"), encoding: .utf8)
    #expect(md.contains("\t- Bookmark: Prologue @bookmark @location(p. 3) @date("))
    #expect(md.contains("@open(scriptorium://open?doc=doc&page=2&progress=0.5000)"))

    var removed = merged
    removed.bookmarks.removeAll { $0.id == b12.id }
    removed.deleted.insert(b12.id)
    #expect(try await store.save(removed, locationLabel: label).bookmarks.map(\.label) == ["p. 3"])
    #expect(await store.allBooks().map(\.documentID) == ["doc"])
}

@Test func deepLinksRoundTrip() {
    let id = UUID()
    let link = DeepLink(documentID: "a1b2", page: 7, progress: 0.25, highlightID: id)
    #expect(link.url.absoluteString.hasPrefix("scriptorium://open?doc=a1b2&page=7&progress=0.2500&highlight="))
    #expect(DeepLink(url: link.url) == DeepLink(documentID: "a1b2", page: 7, progress: 0.25, highlightID: id))
    #expect(DeepLink(url: URL(string: "scriptorium://open?page=1")!) == nil)       // no document
    #expect(DeepLink(url: URL(string: "https://example.com")!) == nil)
}

@Test func improvementNotesAppendWithContextAndScreenshot() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/Improvement notes.md")
    let notes = ImprovementNotes(file: file)
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let shot = try notes.add("Back pill should fade\nIt stays after I read on.", context: "Pride and Prejudice, p. 34",
                             build: "1.0 (6)", device: "iPad Air", screenshot: png)
    try notes.add("List rows too tall on iPhone", context: "Library", build: "1.0 (6)", device: "iPhone")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.hasPrefix("Improvement notes:\n\t- Back pill should fade @date("))
    #expect(text.contains("@where(Pride and Prejudice, p. 34) @build(1.0 [6]) @device(iPad Air) @screenshot(Improvement notes/Screenshot "))
    #expect(text.contains("\n\t\tIt stays after I read on.\n\t- List rows too tall on iPhone"))
    #expect(FileManager.default.fileExists(atPath: notes.attachmentsDirectory.appending(path: try #require(shot)).path))
}
