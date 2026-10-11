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

    public var isEmpty: Bool {
        lines.allSatisfy { $0.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
    }
}

public enum DocumentError: LocalizedError {
    case cannotOpen(URL)
    case unsupportedFormat(String)
    case renderFailed(page: Int)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): "Cannot open \(url.lastPathComponent)"
        case .unsupportedFormat(let ext): "Unsupported format: .\(ext)"
        case .renderFailed(let page): "Failed to render page \(page + 1)"
        }
    }
}

public enum DocumentOpener {
    public static func canOpen(_ url: URL) -> Bool {
        ["pdf", "djvu", "djv", "epub"].contains(url.pathExtension.lowercased()) || FB2Source.canOpen(url)
    }

    public static func open(_ url: URL) throws -> PageSource {
        if FB2Source.canOpen(url) { return try FB2Source(url: url) }
        switch url.pathExtension.lowercased() {
        case "pdf": return try PDFPageSource(url: url)
        case "djvu", "djv": return try DjVuPageSource(url: url)
        case "epub": return try EPUBSource(url: url)
        case let ext: throw DocumentError.unsupportedFormat(ext)
        }
    }
}
