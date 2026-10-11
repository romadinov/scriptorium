import CoreGraphics
import Foundation
import ZIPFoundation

/// EPUB 2/3. The archive is extracted once into Caches; chapters are the spine's XHTML files.
public final class EPUBSource: ReflowableSource, @unchecked Sendable {
    public let url: URL
    public let contentRoot: URL
    public let title: String?
    public private(set) var chapterTitles: [String] = []
    public private(set) var outline: [OutlineItem] = []

    private var spine: [URL] = []
    private var coverURL: URL?
    private let textLock = NSLock()
    private var textCache: [Int: PageText] = [:]

    public init(url: URL) throws {
        self.url = url
        contentRoot = BookCache.directory(for: url, kind: "Books")
        try Self.extractIfNeeded(url, to: contentRoot)

        let container = try MiniXML.parse(contentsOf: contentRoot.appending(path: "META-INF/container.xml"))
        guard let opfPath = container.firstDescendant("rootfile")?.attribute("full-path") else {
            throw DocumentError.cannotOpen(url)
        }
        let opfURL = contentRoot.appending(path: opfPath)
        let opfDir = opfURL.deletingLastPathComponent()
        let opf = try MiniXML.parse(contentsOf: opfURL)

        title = opf.firstDescendant("title")?.text

        // Manifest: id → (href, media type, properties)
        struct Item { let url: URL; let mediaType: String; let properties: String }
        var manifest: [String: Item] = [:]
        for item in opf.firstDescendant("manifest")?.children("item") ?? [] {
            guard let id = item.attribute("id"), let href = item.attribute("href") else { continue }
            manifest[id] = Item(url: Self.resolve(href, relativeTo: opfDir),
                                mediaType: item.attribute("media-type") ?? "",
                                properties: item.attribute("properties") ?? "")
        }

        let spineElement = opf.firstDescendant("spine")
        spine = (spineElement?.children("itemref") ?? []).compactMap { manifest[$0.attribute("idref") ?? ""]?.url }
        guard !spine.isEmpty else { throw DocumentError.cannotOpen(url) }

        // Cover: EPUB3 `properties="cover-image"`, else EPUB2 `<meta name="cover" content="id">`.
        let coverMeta = opf.descendants("meta").first { $0.attribute("name") == "cover" }?.attribute("content")
        coverURL = manifest.values.first { $0.properties.split(separator: " ").contains("cover-image") }?.url
            ?? coverMeta.flatMap { manifest[$0]?.url }

        // Table of contents: EPUB3 nav document, else EPUB2 NCX.
        if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let root = try? MiniXML.parse(contentsOf: nav.url) {
            let tocNav = root.descendants("nav").first { $0.attribute("type") == "toc" } ?? root.firstDescendant("nav")
            if let list = tocNav?.firstDescendant("ol") {
                outline = navItems(list, base: nav.url.deletingLastPathComponent())
            }
        }
        if outline.isEmpty, let ncxID = spineElement?.attribute("toc"), let ncx = manifest[ncxID],
           let root = try? MiniXML.parse(contentsOf: ncx.url), let navMap = root.firstDescendant("navMap") {
            outline = ncxItems(navMap, base: ncx.url.deletingLastPathComponent())
        }

        chapterTitles = spine.indices.map { index in
            Self.firstTitle(in: outline, for: index) ?? "Section \(index + 1)"
        }
    }

    // MARK: PageSource

    public var pageCount: Int { spine.count }

    public func pageSize(at index: Int) -> CGSize { CGSize(width: 600, height: 800) }

    public func renderPage(at index: Int, maxPixelSize: Int) throws -> CGImage {
        guard let coverURL, let image = ImageLoader.load(coverURL, maxPixelSize: maxPixelSize) else {
            throw DocumentError.renderFailed(page: index)
        }
        return image
    }

    public func embeddedText(at index: Int) -> PageText? {
        guard spine.indices.contains(index) else { return nil }
        textLock.lock()
        defer { textLock.unlock() }
        if let cached = textCache[index] { return cached }
        let text = HTMLText.pageText(fromHTMLFile: spine[index])
        textCache[index] = text
        return text
    }

    public func chapterURL(at index: Int) -> URL { spine[min(max(0, index), spine.count - 1)] }

    // MARK: Parsing helpers

    private static func extractIfNeeded(_ archive: URL, to directory: URL) throws {
        let marker = directory.appending(path: ".extracted")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: archive, to: directory)
        try Data().write(to: marker)
    }

    static func resolve(_ href: String, relativeTo base: URL) -> URL {
        let path = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        let decoded = path.removingPercentEncoding ?? path
        return base.appending(path: decoded).standardizedFileURL
    }

    private func spineIndex(for href: String, base: URL) -> Int? {
        let target = Self.resolve(href, relativeTo: base).path
        return spine.firstIndex { $0.standardizedFileURL.path == target }
    }

    private func navItems(_ list: XElement, base: URL) -> [OutlineItem] {
        list.children("li").compactMap { li in
            let link = li.child("a") ?? li.child("span")
            guard let link else { return nil }
            let page = link.attribute("href").flatMap { spineIndex(for: $0, base: base) }
            let children = li.child("ol").map { navItems($0, base: base) } ?? []
            return OutlineItem(title: link.text, pageIndex: page, children: children)
        }
    }

    private func ncxItems(_ parent: XElement, base: URL) -> [OutlineItem] {
        parent.children("navPoint").map { point in
            let title = point.child("navLabel")?.text ?? "—"
            let page = point.child("content")?.attribute("src").flatMap { spineIndex(for: $0, base: base) }
            return OutlineItem(title: title, pageIndex: page, children: ncxItems(point, base: base))
        }
    }

    private static func firstTitle(in items: [OutlineItem], for index: Int) -> String? {
        for item in items {
            if item.pageIndex == index { return item.title }
            if let nested = firstTitle(in: item.children, for: index) { return nested }
        }
        return nil
    }
}
