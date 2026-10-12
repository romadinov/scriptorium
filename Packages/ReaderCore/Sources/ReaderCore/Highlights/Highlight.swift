import CoreGraphics
import CryptoKit
import Foundation

public struct Highlight: Codable, Hashable, Identifiable, Sendable {
    public enum Color: String, Codable, CaseIterable, Sendable {
        case yellow, green, blue, pink

        /// sRGB components used by every viewer, so colours match across formats.
        public var rgb: (r: Double, g: Double, b: Double) {
            switch self {
            case .yellow: (1.0, 0.85, 0.2)
            case .green: (0.45, 0.85, 0.4)
            case .blue: (0.4, 0.7, 1.0)
            case .pink: (1.0, 0.5, 0.7)
            }
        }
    }

    /// Where the highlight sits. Every case also carries the page/chapter for sorting and navigation.
    public enum Location: Codable, Hashable, Sendable {
        /// PDF page-space rectangles (points, PDF coordinates), possibly spanning pages.
        case pdf(rects: [PageRect])
        /// Normalised (0…1, top-left origin) rectangles on a rendered page image — DjVu and scans.
        case image(page: Int, rects: [CGRect])
        /// Character offsets into a reflowable chapter's text, plus surrounding text to re-anchor if offsets drift.
        case text(chapter: Int, start: Int, end: Int, prefix: String, suffix: String)

        public var pageIndex: Int {
            switch self {
            case .pdf(let rects): rects.first?.page ?? 0
            case .image(let page, _): page
            case .text(let chapter, _, _, _, _): chapter
            }
        }
    }

    public struct PageRect: Codable, Hashable, Sendable {
        public var page: Int
        public var rect: CGRect
        public init(page: Int, rect: CGRect) {
            self.page = page
            self.rect = rect
        }
    }

    public var id: UUID
    public var text: String
    public var color: Color
    public var created: Date
    public var note: String?
    /// Apple Pencil sketch attached to the highlight (see `HighlightStore.saveDrawing`).
    public var drawingID: UUID?
    /// Last edit of the note/drawing; the newer copy wins when devices merge.
    public var modified: Date?
    public var location: Location

    public init(id: UUID = UUID(), text: String, color: Color = .yellow, created: Date = Date(),
                note: String? = nil, drawingID: UUID? = nil, modified: Date? = nil, location: Location) {
        self.id = id
        self.text = text
        self.color = color
        self.created = created
        self.note = note
        self.drawingID = drawingID
        self.modified = modified
        self.location = location
    }
}

/// Something a note (text and/or drawing) can be attached to: a highlight, or a page via its bookmark.
public protocol Annotatable {
    var id: UUID { get }
    var note: String? { get set }
    var drawingID: UUID? { get set }
    var created: Date { get }
    var modified: Date? { get set }
}

extension Annotatable {
    public var hasNote: Bool { !(note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    public var hasAnnotation: Bool { hasNote || drawingID != nil }
    var lastEdit: Date { modified ?? created }
}

extension Highlight: Annotatable {}
extension Bookmark: Annotatable {}

/// A bookmarked place: a page (fixed layout) or a chapter + position within it (reflowable).
public struct Bookmark: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var page: Int
    public var progress: Double
    /// As shown when it was made, e.g. "p. 12".
    public var label: String
    /// The first words on the page, so bookmarks are recognisable and searchable.
    public var snippet: String
    public var created: Date
    /// A page note: text and/or an Apple Pencil drawing.
    public var note: String?
    public var drawingID: UUID?
    public var modified: Date?

    public init(id: UUID = UUID(), page: Int, progress: Double = 0, label: String, snippet: String, created: Date = Date(),
                note: String? = nil, drawingID: UUID? = nil, modified: Date? = nil) {
        self.id = id
        self.page = page
        self.progress = progress
        self.label = label
        self.snippet = snippet
        self.created = created
        self.note = note
        self.drawingID = drawingID
        self.modified = modified
    }
}

/// All highlights and bookmarks for one document, as stored in iCloud.
public struct BookHighlights: Codable, Sendable, Equatable {
    public var documentID: String
    public var title: String
    public var fileName: String
    /// Library-relative path when last saved — a hint for finding the book again (the fingerprint decides).
    public var path: String?
    public var highlights: [Highlight]
    public var bookmarks: [Bookmark]
    /// IDs deleted on any device; kept so a merge with an older copy doesn't resurrect them.
    public var deleted: Set<UUID>
    public var updated: Date

    public init(documentID: String, title: String, fileName: String, path: String? = nil,
                highlights: [Highlight] = [], bookmarks: [Bookmark] = [], deleted: Set<UUID> = [], updated: Date = Date()) {
        self.documentID = documentID
        self.title = title
        self.fileName = fileName
        self.path = path
        self.highlights = highlights
        self.bookmarks = bookmarks
        self.deleted = deleted
        self.updated = updated
    }

    // Files written before bookmarks existed lack those keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try c.decode(String.self, forKey: .documentID)
        title = try c.decode(String.self, forKey: .title)
        fileName = try c.decode(String.self, forKey: .fileName)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        highlights = try c.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        deleted = try c.decodeIfPresent(Set<UUID>.self, forKey: .deleted) ?? []
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
    }

    /// Union of both sides by id, minus anything either side deleted; where both have an item, the more
    /// recently edited copy wins (so a note edited on another device isn't lost). Sorted in reading order.
    public func merged(with other: BookHighlights) -> BookHighlights {
        var result = self
        result.deleted = deleted.union(other.deleted)
        var byID = Dictionary(highlights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for h in other.highlights where byID[h.id].map({ h.lastEdit > $0.lastEdit }) ?? true { byID[h.id] = h }
        result.highlights = byID.values.filter { !result.deleted.contains($0.id) }.sorted(by: Self.readingOrder)
        var marks = Dictionary(bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for b in other.bookmarks where marks[b.id].map({ b.lastEdit > $0.lastEdit }) ?? true { marks[b.id] = b }
        result.bookmarks = marks.values.filter { !result.deleted.contains($0.id) }
            .sorted { ($0.page, $0.progress) < ($1.page, $1.progress) }
        result.path = path ?? other.path
        result.updated = max(updated, other.updated)
        return result
    }

    public static func readingOrderPublic(_ a: Highlight, _ b: Highlight) -> Bool { readingOrder(a, b) }

    static func readingOrder(_ a: Highlight, _ b: Highlight) -> Bool {
        let (pa, pb) = (a.location.pageIndex, b.location.pageIndex)
        if pa != pb { return pa < pb }
        if case .text(_, let sa, _, _, _) = a.location, case .text(_, let sb, _, _, _) = b.location, sa != sb { return sa < sb }
        if case .image(_, let ra) = a.location, case .image(_, let rb) = b.location,
           let ya = ra.first?.minY, let yb = rb.first?.minY, ya != yb { return ya < yb }
        if case .pdf(let ra) = a.location, case .pdf(let rb) = b.location,
           let ya = ra.first?.rect.maxY, let yb = rb.first?.rect.maxY, ya != yb { return ya > yb } // PDF y grows upwards
        return a.created < b.created
    }

    /// Human-readable export ("<Title>.md") in TaskPaper style: the book is a project, each highlight
    /// an item tagged with where it is, when it was made and its colour; notes are indented below.
    public func markdown(locationLabel: (Highlight.Location) -> String) -> String {
        var lines = [TaskPaper.project(title)]
        lines.append(TaskPaper.note("\(fileName) · \(highlights.count) highlight\(highlights.count == 1 ? "" : "s") · updated \(TaskPaper.date(updated))", indent: 1))
        for b in bookmarks {
            let link = DeepLink(documentID: documentID, page: b.page, progress: b.progress).url.absoluteString
            var tags: [(String, String?)] = [(b.hasAnnotation ? "pagenote" : "bookmark", nil), ("location", b.label),
                                             ("date", TaskPaper.date(b.created))]
            if let drawing = b.drawingID { tags.append(("drawing", Self.drawingPath(drawing))) }
            tags.append(("open", link))
            lines.append(TaskPaper.item("\(b.hasAnnotation ? "Page note" : "Bookmark"): \(b.snippet)", tags: tags))
            if let note = b.note, b.hasNote { lines.append(TaskPaper.note(note)) }
        }
        for h in highlights {
            var tags: [(String, String?)] = [("location", locationLabel(h.location)), ("date", TaskPaper.date(h.created))]
            if h.color != .yellow { tags.append(("color", h.color.rawValue)) }
            if let drawing = h.drawingID { tags.append(("drawing", Self.drawingPath(drawing))) }
            tags.append(("open", DeepLink(documentID: documentID, page: h.location.pageIndex, highlightID: h.id).url.absoluteString))
            lines.append(TaskPaper.item(h.text, tags: tags))
            if let note = h.note, h.hasNote { lines.append(TaskPaper.note(note)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Where a drawing's picture sits, relative to the Markdown file.
    public static func drawingPath(_ id: UUID) -> String { "Drawings/\(id.uuidString).png" }
}

/// `scriptorium://open?doc=<fingerprint>&page=<n>&progress=<0…1>&highlight=<uuid>` — opens a book at a place.
public struct DeepLink: Equatable, Sendable {
    public static let scheme = "scriptorium"
    public var documentID: String
    public var page: Int
    public var progress: Double
    public var highlightID: UUID?

    public init(documentID: String, page: Int, progress: Double = 0, highlightID: UUID? = nil) {
        self.documentID = documentID
        self.page = page
        self.progress = progress
        self.highlightID = highlightID
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host() == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let doc = items.first(where: { $0.name == "doc" })?.value, !doc.isEmpty else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        documentID = doc
        page = value("page").flatMap(Int.init) ?? 0
        progress = value("progress").flatMap(Double.init) ?? 0
        highlightID = value("highlight").flatMap(UUID.init(uuidString:))
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "doc", value: documentID), URLQueryItem(name: "page", value: String(page))]
        if progress > 0 { c.queryItems?.append(URLQueryItem(name: "progress", value: String(format: "%.4f", progress))) }
        if let highlightID { c.queryItems?.append(URLQueryItem(name: "highlight", value: highlightID.uuidString)) }
        return c.url!
    }
}

public enum DocumentFingerprint {
    /// Stable id for a book file: hash of its size plus the first and last 256 KB.
    /// Survives renames and moves, and is the same on every device holding the same file.
    public static func id(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var hasher = SHA256()
        hasher.update(data: Data(String(size).utf8))
        try handle.seek(toOffset: 0)
        hasher.update(data: try handle.read(upToCount: 256 * 1024) ?? Data())
        if size > 512 * 1024 {
            try handle.seek(toOffset: size - 256 * 1024)
            hasher.update(data: try handle.read(upToCount: 256 * 1024) ?? Data())
        }
        return hasher.finalize().prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

extension PageText {
    /// Rectangles (one per line) of the words that best match `selection` — used to draw highlights
    /// for Live Text selections, whose geometry VisionKit doesn't expose. `nil` if nothing matches well.
    public func rects(matching selection: String) -> [CGRect]? {
        func tokens(_ s: String) -> [String] {
            s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let target = tokens(selection)
        guard !target.isEmpty else { return nil }

        // Flatten words with their line index; each OCR word may itself contain several tokens.
        var flat: [(token: String, rect: CGRect, line: Int)] = []
        for (lineIndex, line) in lines.enumerated() {
            for word in line {
                for token in tokens(word.text) { flat.append((token, word.rect, lineIndex)) }
            }
        }
        guard flat.count >= target.count else { return nil }

        // Slide a window of the selection's length; keep the one with the most equal tokens.
        var best = (score: 0, start: 0)
        for start in 0...(flat.count - target.count) {
            var score = 0
            for i in 0..<target.count where flat[start + i].token == target[i] { score += 1 }
            if score > best.score { best = (score, start) }
            if score == target.count { break }
        }
        guard Double(best.score) >= Double(target.count) * 0.6 else { return nil }

        // Merge per line into one rect each.
        var merged: [Int: CGRect] = [:]
        var order: [Int] = []
        for item in flat[best.start..<(best.start + target.count)] {
            if let existing = merged[item.line] {
                merged[item.line] = existing.union(item.rect)
            } else {
                merged[item.line] = item.rect
                order.append(item.line)
            }
        }
        return order.compactMap { merged[$0] }
    }
}
