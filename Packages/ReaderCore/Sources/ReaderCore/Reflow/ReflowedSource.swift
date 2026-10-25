import CoreGraphics
import Foundation

/// A PDF or DjVu shown as reflowable text: one chapter per page (so page numbers, positions and the
/// outline carry over), converted on demand by `PageReflower` and cached under Caches/Reflowed.
public final class ReflowedSource: ReflowableSource, @unchecked Sendable {
    public let original: PageSource
    public let contentRoot: URL
    public var url: URL { original.url }
    public var pageCount: Int { original.pageCount }
    public var outline: [OutlineItem] { original.outline }
    public var chapterTitles: [String] { (0..<pageCount).map { "Page \($0 + 1)" } }

    /// Bumped when conversion improves, so pages converted by older code are converted again.
    static let converterVersion = "2"

    public init(original: PageSource) {
        self.original = original
        contentRoot = Self.directory(for: original.url)
        let version = contentRoot.appending(path: ".converter-version")
        if (try? String(contentsOf: version, encoding: .utf8)) != Self.converterVersion {
            try? FileManager.default.removeItem(at: contentRoot)
        }
        try? FileManager.default.createDirectory(at: contentRoot, withIntermediateDirectories: true)
        try? Self.converterVersion.write(to: version, atomically: true, encoding: .utf8)
    }

    public static func directory(for book: URL) -> URL { BookCache.directory(for: book, kind: "Reflowed") }
    static func stem(_ index: Int) -> String { String(format: "page-%05d", index + 1) }

    public func isConverted(_ index: Int) -> Bool {
        FileManager.default.fileExists(atPath: contentRoot.appending(path: "\(Self.stem(index)).xhtml").path)
    }

    public var convertedCount: Int { (0..<pageCount).filter(isConverted).count }

    public func chapterURL(at index: Int) -> URL {
        let page = contentRoot.appending(path: "\(Self.stem(index)).xhtml")
        if FileManager.default.fileExists(atPath: page.path) { return page }
        // Not converted yet: a placeholder (the reader reloads once conversion reaches this page).
        let pending = contentRoot.appending(path: "pending.xhtml")
        if !FileManager.default.fileExists(atPath: pending.path) {
            try? Data("""
            <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="UTF-8"/></head>
            <body><p style="text-align:center;opacity:0.6">Converting this page to text…</p></body></html>
            """.utf8).write(to: pending)
        }
        return pending
    }

    /// Converts the pages not yet done, starting at `start` and wrapping around. `progress` gets the
    /// fraction done and each page as it finishes. Cancellable between pages.
    public func convert(from start: Int, languages: [String],
                        progress: @Sendable (Double, Int) async -> Void) async throws {
        let order = (start..<pageCount).map { $0 } + (0..<min(start, pageCount)).map { $0 }
        var done = convertedCount
        for index in order where !isConverted(index) {
            try Task.checkCancellation()
            try await PageReflower.convert(original, page: index, into: contentRoot, languages: languages)
            done += 1
            await progress(Double(done) / Double(max(1, pageCount)), index)
        }
    }

    public func pageSize(at index: Int) -> CGSize { original.pageSize(at: index) }
    public func renderPage(at index: Int, maxPixelSize: Int) throws -> CGImage { try original.renderPage(at: index, maxPixelSize: maxPixelSize) }
    public func embeddedText(at index: Int) -> PageText? {
        isConverted(index) ? HTMLText.pageText(fromHTMLFile: chapterURL(at: index)) : original.embeddedText(at: index)
    }
}
