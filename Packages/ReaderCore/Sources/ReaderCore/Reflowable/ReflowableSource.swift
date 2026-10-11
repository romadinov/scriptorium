import CoreGraphics
import Foundation
import ImageIO

/// A reflowable book (EPUB, FB2) shown chapter by chapter in a web view.
/// As a `PageSource`, one "page" is one chapter, so the reader's page logic, outline and
/// LLM context code work unchanged; `renderPage` returns the cover for thumbnails.
public protocol ReflowableSource: PageSource {
    /// Directory holding the extracted or generated chapter files. The web view gets read access to it.
    var contentRoot: URL { get }
    var chapterTitles: [String] { get }
    func chapterURL(at index: Int) -> URL
}

enum BookCache {
    /// A per-file working directory under Caches, keyed by name and size.
    static func directory(for url: URL, kind: String) -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return root.appending(path: kind).appending(path: key(for: url))
    }

    static func key(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .prefix(60)
        return "\(name)-\(size)"
    }
}

enum ImageLoader {
    /// Decodes an image file and downsamples it so its longer side is at most `maxPixelSize`.
    static func load(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Plain text of an (X)HTML chapter, one paragraph per line, for the LLM and search.
enum HTMLText {
    private static let blockElements: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "br", "tr", "section", "pre", "dd", "dt",
    ]

    static func pageText(fromHTMLFile url: URL) -> PageText? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let paragraphs: [String]
        if let root = try? MiniXML.parse(data), let body = root.firstDescendant("body") ?? Optional(root) {
            var lines: [String] = []
            var current = ""
            collect(body, lines: &lines, current: &current)
            lines.append(current)
            paragraphs = lines
        } else {
            paragraphs = stripTags(String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
        }
        let cleaned = paragraphs
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return PageText(origin: .embedded, lines: cleaned.map { [PageText.Word(text: $0, rect: .zero)] })
    }

    private static func collect(_ element: XElement, lines: inout [String], current: inout String) {
        if ["script", "style", "head"].contains(element.name) { return }
        let isBlock = blockElements.contains(element.name)
        if isBlock, !current.isEmpty { lines.append(current); current = "" }
        for child in element.children {
            switch child {
            case .text(let t): current += t
            case .element(let e): collect(e, lines: &lines, current: &current)
            }
        }
        if isBlock, !current.isEmpty { lines.append(current); current = "" }
    }

    /// Fallback for tag soup that XMLParser rejects.
    static func stripTags(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "(?is)<(script|style|head)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</?(p|div|br|h[1-6]|li|blockquote|tr)[^>]*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: entity, with: value)
        }
        return s
    }
}

extension ReflowableSource {
    /// The chapter a file URL belongs to (for following in-book links).
    public func chapterIndex(for url: URL) -> Int? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return (0..<pageCount).first { chapterURL(at: $0).standardizedFileURL.resolvingSymlinksInPath().path == target }
    }
}
