import CoreGraphics
import Foundation

/// A paginated document that can be rendered to images and queried for text.
/// Implemented by `PDFPageSource` and `DjVuPageSource`.
public protocol PageSource: AnyObject, Sendable {
    var url: URL { get }
    var pageCount: Int { get }
    var outline: [OutlineItem] { get }

    /// Page size in points (1/72 in) — used for layout before the page is rendered.
    func pageSize(at index: Int) -> CGSize

    /// Renders a page so that its longer side is at most `maxPixelSize` pixels.
    func renderPage(at index: Int, maxPixelSize: Int) throws -> CGImage

    /// Text embedded in the file (PDF text layer, DjVu hidden text). `nil` for scans without text.
    func embeddedText(at index: Int) -> PageText?
}

public struct OutlineItem: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var title: String
    public var pageIndex: Int?
    public var children: [OutlineItem]

    public init(title: String, pageIndex: Int?, children: [OutlineItem] = []) {
        self.title = title
        self.pageIndex = pageIndex
        self.children = children
    }
}

/// Words on a page with bounding boxes normalised to 0...1, origin top-left.
public struct PageText: Codable, Hashable, Sendable {
    public struct Word: Codable, Hashable, Sendable {
        public var text: String
        public var rect: CGRect
        public init(text: String, rect: CGRect) {
            self.text = text
            self.rect = rect
        }
    }

    public enum Origin: String, Codable, Sendable { case embedded, ocr }

    public var origin: Origin
    /// Lines in reading order; each line is a list of words.
    public var lines: [[Word]]

    public init(origin: Origin, lines: [[Word]]) {
        self.origin = origin
        self.lines = lines
    }

    public var plainText: String {
        lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }

    /// UTF-16 offset in `plainText` of the word at `point` (same coordinate space as the word rects),
    /// or of the nearest word on that line; nil if the point isn't on any line.
    public func characterOffset(at point: CGPoint) -> Int? {
        var offset = 0
        var best: (offset: Int, distance: CGFloat)?
        for line in lines {
            var wordOffset = offset
            for word in line {
                let rect = word.rect
                let lineTop = min(rect.minY, rect.maxY), lineBottom = max(rect.minY, rect.maxY)
                let slack = (lineBottom - lineTop) * 0.3
                if point.y >= lineTop - slack && point.y <= lineBottom + slack {
                    let dx = point.x < rect.minX ? rect.minX - point.x : (point.x > rect.maxX ? point.x - rect.maxX : 0)
                    if dx == 0 { return wordOffset }
                    if best == nil || dx < best!.distance { best = (wordOffset, dx) }
                }
                wordOffset += (word.text as NSString).length + 1
            }
            offset += (line.map(\.text).joined(separator: " ") as NSString).length + 1
        }
        return best?.offset
    }

    public var isEmpty: Bool {
        lines.allSatisfy { $0.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
    }
}

public enum DocumentError: LocalizedError {
    case cannotOpen(URL)
    case unsupportedFormat(String)
    case renderFailed(page: Int)
    /// Needs a one-time conversion by the app first (old `.doc` files, converted with WebKit).
    case needsConversion

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): "Cannot open \(url.lastPathComponent)"
        case .unsupportedFormat(let ext): "Unsupported format: .\(ext)"
        case .renderFailed(let page): "Failed to render page \(page + 1)"
        case .needsConversion: "This document needs converting first"
        }
    }
}

public enum DocumentOpener {
    public static func canOpen(_ url: URL) -> Bool {
        ["pdf", "djvu", "djv", "epub", "webarchive", "chm"].contains(url.pathExtension.lowercased()) || FB2Source.canOpen(url) || DOCXSource.canOpen(url) || DOCSource.canOpen(url) || AZW3Source.canOpen(url)
    }

    public static func open(_ url: URL) throws -> PageSource {
        if FB2Source.canOpen(url) { return try FB2Source(url: url) }
        if DOCXSource.canOpen(url) { return try DOCXSource(url: url) }
        if DOCSource.canOpen(url) { return try DOCSource(url: url) }
        if AZW3Source.canOpen(url) { return try AZW3Source(url: url) }
        switch url.pathExtension.lowercased() {
        case "pdf": return try PDFPageSource(url: url)
        case "djvu", "djv": return try DjVuPageSource(url: url)
        case "epub": return try EPUBSource(url: url)
        case "webarchive": return try WebArchiveSource(url: url)
        case "chm": return try CHMSource(url: url)
        case let ext: throw DocumentError.unsupportedFormat(ext)
        }
    }
}
