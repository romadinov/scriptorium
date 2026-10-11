import CoreGraphics
import Foundation

/// Safari web archive (`.webarchive`, a binary plist). Converted once into a folder — the page's HTML
/// plus its images/stylesheets as files — and shown as a one-chapter reflowable book, so it gets
/// pages/scroll, highlights and the assistant like any other book. Scripts are removed: an archived
/// page is read, not run.
public final class WebArchiveSource: ReflowableSource, @unchecked Sendable {
    public let url: URL
    public let contentRoot: URL
    public private(set) var title: String?
    public let outline: [OutlineItem] = []
    public var chapterTitles: [String] { [title ?? url.deletingPathExtension().lastPathComponent] }

    private let page: URL
    private var coverURL: URL?
    private let textLock = NSLock()
    private var cachedText: PageText??

    struct Resource {
        var url: URL?
        var data: Data
        var mimeType: String
        var encoding: String?
    }

    public init(url: URL) throws {
        self.url = url
        contentRoot = BookCache.directory(for: url, kind: "Books")
        page = contentRoot.appending(path: "index.html")
        let manifest = contentRoot.appending(path: "archive.json")
        if let data = try? Data(contentsOf: manifest),
           let info = try? JSONDecoder().decode([String: String].self, from: data),
           FileManager.default.fileExists(atPath: page.path) {
            title = info["title"]
            coverURL = info["cover"].map { contentRoot.appending(path: $0) }
            return
        }

        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        guard let archive = plist as? [String: Any], let main = (archive["WebMainResource"] as? [String: Any]).flatMap(Self.resource)
        else { throw DocumentError.cannotOpen(url) }
        let subresources = (archive["WebSubresources"] as? [[String: Any]] ?? []).compactMap(Self.resource)

        try? FileManager.default.removeItem(at: contentRoot)
        try FileManager.default.createDirectory(at: contentRoot.appending(path: "res"), withIntermediateDirectories: true)

        // Write subresources and build original URL → local relative path.
        var local: [String: String] = [:]
        for (index, resource) in subresources.enumerated() {
            guard let original = resource.url else { continue }
            let ext = Self.fileExtension(for: resource.mimeType, url: original)
            let name = "res/\(index).\(ext)"
            local[Self.key(original)] = name
            try resource.data.write(to: contentRoot.appending(path: name))
        }
        // Stylesheets reference fonts and images too; rewrite them relative to their own location.
        for (index, resource) in subresources.enumerated() where resource.mimeType == "text/css" {
            guard let base = resource.url else { continue }
            let css = Self.decode(resource)
            let rewritten = Self.rewriteCSS(css, base: base, local: local, prefix: "")
            let ext = Self.fileExtension(for: resource.mimeType, url: base)
            try Data(rewritten.utf8).write(to: contentRoot.appending(path: "res/\(index).\(ext)"))
        }

        var html = Self.decode(main)
        let base = main.url ?? URL(string: "about:blank")!
        html = Self.stripScripts(html)
        html = Self.rewriteHTML(html, base: base, local: local)
        try Data(html.utf8).write(to: page)

        title = Self.extractTitle(html)
        // The largest raster picture doubles as the library thumbnail (skip icons and SVG).
        coverURL = subresources
            .filter { ["image/jpeg", "image/png", "image/webp"].contains($0.mimeType) && $0.data.count > 4_000 && $0.url != nil }
            .max { $0.data.count < $1.data.count }
            .flatMap { local[Self.key($0.url!)] }
            .map { contentRoot.appending(path: $0) }
        var info: [String: String] = [:]
        info["title"] = title
        info["cover"] = coverURL.map { String($0.path.dropFirst(contentRoot.path.count + 1)) }
        try JSONEncoder().encode(info).write(to: manifest)
    }

    // MARK: PageSource

    public var pageCount: Int { 1 }

    public func pageSize(at index: Int) -> CGSize { CGSize(width: 800, height: 1100) }

    public func renderPage(at index: Int, maxPixelSize: Int) throws -> CGImage {
        guard let coverURL, let image = ImageLoader.load(coverURL, maxPixelSize: maxPixelSize) else {
            throw DocumentError.renderFailed(page: index)
        }
        return image
    }

    public func embeddedText(at index: Int) -> PageText? {
        textLock.lock()
        defer { textLock.unlock() }
        if let cachedText { return cachedText }
        let text = HTMLText.pageText(fromHTMLFile: page)
        cachedText = .some(text)
        return text
    }

    public func chapterURL(at index: Int) -> URL { page }

    // MARK: Conversion helpers

    private static func resource(_ dict: [String: Any]) -> Resource? {
        guard let data = dict["WebResourceData"] as? Data else { return nil }
        return Resource(url: (dict["WebResourceURL"] as? String).flatMap(URL.init(string:)),
                        data: data,
                        mimeType: (dict["WebResourceMIMEType"] as? String ?? "application/octet-stream").lowercased(),
                        encoding: dict["WebResourceTextEncodingName"] as? String)
    }

    private static func decode(_ resource: Resource) -> String {
        if let name = resource.encoding {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let string = String(data: resource.data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return string
            }
        }
        return String(data: resource.data, encoding: .utf8) ?? String(decoding: resource.data, as: UTF8.self)
    }

    /// URLs are matched without their fragment.
    static func key(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    private static func fileExtension(for mime: String, url: URL) -> String {
        let known = ["text/css": "css", "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
                     "image/webp": "webp", "image/svg+xml": "svg", "font/woff2": "woff2", "font/woff": "woff",
                     "application/font-woff": "woff", "font/ttf": "ttf", "image/avif": "avif"]
        if let ext = known[mime] { return ext }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || ext.count > 5 ? "bin" : ext
    }

    static func stripScripts(_ html: String) -> String {
        var out = html.replacingOccurrences(of: "(?is)<script\\b[^>]*>.*?</script\\s*>", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "(?is)<noscript\\b[^>]*>(.*?)</noscript\\s*>", with: "$1", options: .regularExpression)
        // Inline handlers (onclick=…) would be dead anyway; drop them.
        out = out.replacingOccurrences(of: "(?i)\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*')", with: "", options: .regularExpression)
        return out
    }

    /// Rewrites src/href/poster/srcset attributes and inline CSS url()s to the local copies.
    static func rewriteHTML(_ html: String, base: URL, local: [String: String]) -> String {
        func resolve(_ value: String) -> String? {
            // Attribute values are HTML-escaped ("&amp;" in query strings); archive URLs are not.
            let trimmed = value.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#38;", with: "&")
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("data:"),
                  let absolute = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return nil }
            return local[key(absolute)]
        }
        let attribute = try! NSRegularExpression(pattern: "(?i)(\\s(?:src|href|poster|data-src)\\s*=\\s*)([\"'])(.*?)\\2")
        var out = replace(attribute, in: html) { match, ns in
            let value = ns.substring(with: match.range(at: 3))
            guard let path = resolve(value) else { return nil }
            return ns.substring(with: match.range(at: 1)) + ns.substring(with: match.range(at: 2)) + path + ns.substring(with: match.range(at: 2))
        }
        let srcset = try! NSRegularExpression(pattern: "(?i)(\\ssrcset\\s*=\\s*)([\"'])(.*?)\\2")
        out = replace(srcset, in: out) { match, ns in
            let candidates = ns.substring(with: match.range(at: 3)).split(separator: ",").map { candidate -> String in
                let parts = candidate.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                guard let first = parts.first, let path = resolve(String(first)) else { return String(candidate) }
                return ([path] + parts.dropFirst().map(String.init)).joined(separator: " ")
            }
            return ns.substring(with: match.range(at: 1)) + ns.substring(with: match.range(at: 2))
                + candidates.joined(separator: ", ") + ns.substring(with: match.range(at: 2))
        }
        return rewriteCSS(out, base: base, local: local, prefix: "")
    }

    /// url(...) references in CSS (stylesheets live in res/, so their targets are siblings).
    static func rewriteCSS(_ css: String, base: URL, local: [String: String], prefix: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "url\\(\\s*([\"']?)([^\"')]+)\\1\\s*\\)")
        let inStylesheet = !(base.pathExtension.lowercased().contains("htm")) && base.absoluteString != "about:blank"
        return replace(pattern, in: css) { match, ns in
            let value = ns.substring(with: match.range(at: 2))
            guard !value.hasPrefix("data:"), let absolute = URL(string: value, relativeTo: base)?.absoluteURL,
                  let path = local[key(absolute)] else { return nil }
            // From res/x.css, a sibling is just "y.png"; from index.html it is "res/y.png".
            let relative = inStylesheet && path.hasPrefix("res/") ? String(path.dropFirst(4)) : path
            return "url(\"\(prefix)\(relative)\")"
        }
    }

    private static func replace(_ regex: NSRegularExpression, in string: String,
                                with transform: (NSTextCheckingResult, NSString) -> String?) -> String {
        let ns = string as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform(match, ns) ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }

    private static func extractTitle(_ html: String) -> String? {
        guard let range = html.range(of: "(?is)<title[^>]*>(.*?)</title>", options: .regularExpression) else { return nil }
        let inner = html[range].replacingOccurrences(of: "(?is)</?title[^>]*>", with: "", options: .regularExpression)
        let text = HTMLText.stripTags(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
