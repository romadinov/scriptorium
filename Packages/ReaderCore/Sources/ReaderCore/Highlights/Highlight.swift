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
    public var location: Location

    public init(id: UUID = UUID(), text: String, color: Color = .yellow, created: Date = Date(),
                note: String? = nil, location: Location) {
        self.id = id
        self.text = text
        self.color = color
        self.created = created
        self.note = note
        self.location = location
    }
}

/// All highlights for one document, as stored in iCloud.
public struct BookHighlights: Codable, Sendable, Equatable {
    public var documentID: String
    public var title: String
    public var fileName: String
    public var highlights: [Highlight]
    /// IDs deleted on any device; kept so a merge with an older copy doesn't resurrect them.
    public var deleted: Set<UUID>
    public var updated: Date

    public init(documentID: String, title: String, fileName: String,
                highlights: [Highlight] = [], deleted: Set<UUID> = [], updated: Date = Date()) {
        self.documentID = documentID
        self.title = title
        self.fileName = fileName
        self.highlights = highlights
        self.deleted = deleted
        self.updated = updated
    }

    /// Union of both sides by id, minus anything either side deleted. Sorted in reading order.
    public func merged(with other: BookHighlights) -> BookHighlights {
        var result = self
        result.deleted = deleted.union(other.deleted)
        var byID = Dictionary(highlights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for h in other.highlights where byID[h.id] == nil { byID[h.id] = h }
        result.highlights = byID.values.filter { !result.deleted.contains($0.id) }.sorted(by: Self.readingOrder)
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

    /// Human-readable export, written next to the data as "<Title>.md".
    public func markdown(locationLabel: (Highlight.Location) -> String) -> String {
        let date = Date.FormatStyle(date: .abbreviated, time: .omitted)
        var out = "# \(title)\n\n"
        out += "_\(fileName)_ · \(highlights.count) highlight\(highlights.count == 1 ? "" : "s") · updated \(updated.formatted(date))\n"
        for h in highlights {
            let quote = h.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
            out += "\n\(quote)\n\n— \(locationLabel(h.location)) · \(h.created.formatted(date))"
            if h.color != .yellow { out += " · \(h.color.rawValue)" }
            out += "\n"
            if let note = h.note, !note.isEmpty { out += "\n\(note)\n" }
        }
        return out
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
