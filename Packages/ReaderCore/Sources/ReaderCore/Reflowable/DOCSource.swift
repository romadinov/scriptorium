import CoreGraphics
import Foundation

/// Old binary Word (`.doc`). Nothing on iOS parses it directly, so the app converts it to HTML once with
/// WebKit (`WordDocConverter`) and saves it with `saveConverted`; this source splits that HTML into
/// chapters at the top heading level.
public final class DOCSource: ReflowableSource, @unchecked Sendable {
    public let url: URL
    public let contentRoot: URL
    public private(set) var chapterTitles: [String] = []
    public private(set) var outline: [OutlineItem] = []
    private var chapters: [URL] = []
    private let textLock = NSLock()
    private var textCache: [Int: PageText] = [:]

    public static func canOpen(_ url: URL) -> Bool { url.pathExtension.lowercased() == "doc" }

    static func convertedURL(for url: URL) -> URL {
        // Versioned: bump when the app's conversion changes so documents are converted again.
        BookCache.directory(for: url, kind: "Books").appending(path: "converted-v2.html")
    }

    public static func isConverted(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: convertedURL(for: url).path)
    }

    public static func saveConverted(html: String, for url: URL) throws {
        let target = convertedURL(for: url)
        try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.write(to: target, atomically: true, encoding: .utf8)
    }

    public init(url: URL) throws {
        self.url = url
        let converted = Self.convertedURL(for: url)
        contentRoot = converted.deletingLastPathComponent()
        guard let html = try? String(contentsOf: converted, encoding: .utf8) else { throw DocumentError.needsConversion }
        let parts = HTMLSplitter.chapters(of: Self.cleanControlCharacters(html))
        for (index, part) in parts.enumerated() {
            let file = contentRoot.appending(path: "ch\(index).html")
            try part.html.write(to: file, atomically: true, encoding: .utf8)   // cheap; never stale
            chapters.append(file)
            chapterTitles.append(part.title ?? (index == 0 ? "Beginning" : "Section \(index + 1)"))
            if let title = part.title { outline.append(OutlineItem(title: title, pageIndex: index, children: [])) }
        }
    }

    /// Word's binary format keeps some marks as control characters that WebKit passes through and fonts
    /// draw as boxes: optional hyphen (U+001F) → soft hyphen, non-breaking hyphen (U+001E) → U+2011;
    /// any other C0 control (field/page/column marks) except tab and line breaks is dropped.
    static func cleanControlCharacters(_ html: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in html.unicodeScalars {
            switch scalar.value {
            case 0x1F: out.append("\u{00AD}")
            case 0x1E: out.append("\u{2011}")
            case 0x09, 0x0A, 0x0D: out.append(scalar)
            case 0x00..<0x20, 0x7F: continue
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    public var pageCount: Int { chapters.count }
    public func pageSize(at index: Int) -> CGSize { CGSize(width: 600, height: 800) }
    public func renderPage(at index: Int, maxPixelSize: Int) throws -> CGImage { throw DocumentError.renderFailed(page: index) }
    public func chapterURL(at index: Int) -> URL { chapters[min(max(0, index), chapters.count - 1)] }

    public func embeddedText(at index: Int) -> PageText? {
        guard chapters.indices.contains(index) else { return nil }
        textLock.lock()
        defer { textLock.unlock() }
        if let cached = textCache[index] { return cached }
        let text = HTMLText.pageText(fromHTMLFile: chapters[index])
        textCache[index] = text
        return text
    }
}

/// Splits one HTML document into chapters at its top heading level (h1, else h2), keeping the head
/// (styles) in every part.
enum HTMLSplitter {
    static func chapters(of html: String) -> [(title: String?, html: String)] {
        let ns = html as NSString
        let head = firstMatch(#"<head[^>]*>[\s\S]*?</head>"#, in: html) ?? ""
        let bodyRange = (try? NSRegularExpression(pattern: #"<body[^>]*>([\s\S]*)</body>"#, options: .caseInsensitive))?
            .firstMatch(in: html, range: NSRange(location: 0, length: ns.length))?.range(at: 1)
        var body = bodyRange.map { ns.substring(with: $0) } ?? html
        // Converters scatter <style> blocks through the body; hoist them so every chapter gets them all
        // and they don't count as content.
        let styleRegex = try! NSRegularExpression(pattern: #"<style[^>]*>[\s\S]*?</style>"#, options: .caseInsensitive)
        let styles = styleRegex.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length))
            .map { (body as NSString).substring(with: $0.range) }.joined()
        body = styleRegex.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
        let fullHead = styles.isEmpty ? head : head.replacingOccurrences(of: "</head>", with: styles + "</head>", options: .caseInsensitive)
        func wrap(_ part: String) -> String { "<!DOCTYPE html><html>\(fullHead)<body>\(part)</body></html>" }

        let level = ["h1", "h2"].first { body.range(of: "<\($0)[\\s>]", options: [.regularExpression, .caseInsensitive]) != nil }
        guard let level else { return [(nil, wrap(body))] }
        let regex = try! NSRegularExpression(pattern: "<\(level)[\\s>][\\s\\S]*?</\(level)>", options: .caseInsensitive)
        let bodyNS = body as NSString
        let headings = regex.matches(in: body, range: NSRange(location: 0, length: bodyNS.length))
        var parts: [(String?, String)] = []
        let before = bodyNS.substring(to: headings[0].range.location)
        if before.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            parts.append((nil, wrap(before)))
        }
        for (i, match) in headings.enumerated() {
            let end = i + 1 < headings.count ? headings[i + 1].range.location : bodyNS.length
            let chunk = bodyNS.substring(with: NSRange(location: match.range.location, length: end - match.range.location))
            let title = bodyNS.substring(with: match.range)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            parts.append((title.isEmpty ? nil : title, wrap(chunk)))
        }
        return parts
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range])
    }
}
