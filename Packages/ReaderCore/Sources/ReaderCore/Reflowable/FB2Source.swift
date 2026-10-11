import CoreGraphics
import Foundation
import ZIPFoundation

/// FictionBook 2 (`.fb2`, or `.fb2.zip`). Converted once to one HTML file per top-level section,
/// with embedded images written out as files, all under Caches.
public final class FB2Source: ReflowableSource, @unchecked Sendable {
    public let url: URL
    public let contentRoot: URL
    public private(set) var title: String?
    public private(set) var chapterTitles: [String] = []
    public private(set) var outline: [OutlineItem] = []

    private var chapters: [URL] = []
    private var coverURL: URL?
    private let textLock = NSLock()
    private var textCache: [Int: PageText] = [:]

    public static func canOpen(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".fb2") || name.hasSuffix(".fb2.zip")
    }

    public init(url: URL) throws {
        self.url = url
        contentRoot = BookCache.directory(for: url, kind: "Books")
        let manifestURL = contentRoot.appending(path: "book.json")
        if let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
           manifest.version == Manifest.currentVersion {
            apply(manifest)
            return
        }
        try? FileManager.default.removeItem(at: contentRoot)
        try FileManager.default.createDirectory(at: contentRoot, withIntermediateDirectories: true)
        let manifest = try Self.convert(try Self.loadXML(url), into: contentRoot)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        apply(manifest)
    }

    // MARK: PageSource

    public var pageCount: Int { chapters.count }

    public func pageSize(at index: Int) -> CGSize { CGSize(width: 600, height: 800) }

    public func renderPage(at index: Int, maxPixelSize: Int) throws -> CGImage {
        guard let coverURL, let image = ImageLoader.load(coverURL, maxPixelSize: maxPixelSize) else {
            throw DocumentError.renderFailed(page: index)
        }
        return image
    }

    public func embeddedText(at index: Int) -> PageText? {
        guard chapters.indices.contains(index) else { return nil }
        textLock.lock()
        defer { textLock.unlock() }
        if let cached = textCache[index] { return cached }
        let text = HTMLText.pageText(fromHTMLFile: chapters[index])
        textCache[index] = text
        return text
    }

    public func chapterURL(at index: Int) -> URL { chapters[min(max(0, index), chapters.count - 1)] }

    // MARK: Conversion

    /// What the converter produced; cached as book.json so re-opening skips the XML parse.
    struct Manifest: Codable {
        struct Entry: Codable {
            var title: String
            var page: Int?
            var children: [Entry]
        }

        /// Bump when conversion changes so cached books are converted again.
        static let currentVersion = 2
        var version: Int? = currentVersion
        var title: String?
        var chapterFiles: [String]
        var chapterTitles: [String]
        var cover: String?
        var outline: [Entry]
    }

    private func apply(_ manifest: Manifest) {
        title = manifest.title
        chapters = manifest.chapterFiles.map { contentRoot.appending(path: $0) }
        chapterTitles = manifest.chapterTitles
        coverURL = manifest.cover.map { contentRoot.appending(path: $0) }
        func items(_ entries: [Manifest.Entry]) -> [OutlineItem] {
            entries.map { OutlineItem(title: $0.title, pageIndex: $0.page, children: items($0.children)) }
        }
        outline = items(manifest.outline)
    }

    private static func loadXML(_ url: URL) throws -> XElement {
        guard url.lastPathComponent.lowercased().hasSuffix(".zip") else { return try MiniXML.parse(contentsOf: url) }
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive.first(where: { $0.path.lowercased().hasSuffix(".fb2") }) else {
            throw DocumentError.cannotOpen(url)
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return try MiniXML.parse(data)
    }

    static func convert(_ root: XElement, into directory: URL) throws -> Manifest {
        // Binaries → img/<id>.<ext>
        var images: [String: String] = [:]
        let imageDir = directory.appending(path: "img")
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        for binary in root.children("binary") {
            guard let id = binary.attribute("id"),
                  let data = Data(base64Encoded: binary.text.replacingOccurrences(of: " ", with: ""),
                                  options: .ignoreUnknownCharacters) else { continue }
            let ext = binary.attribute("content-type")?.split(separator: "/").last.map(String.init) ?? "jpg"
            let name = "img/\(id.replacingOccurrences(of: "/", with: "_")).\(ext)"
            try data.write(to: directory.appending(path: name))
            images[id] = name
        }

        let titleInfo = root.firstDescendant("description")?.child("title-info")
        let bookTitle = titleInfo?.child("book-title")?.text
        let coverID = titleInfo?.child("coverpage")?.child("image")?.attribute("href").map { String($0.drop { $0 == "#" }) }

        let bodies = root.children("body")
        let main = bodies.first { $0.attribute("name") == nil } ?? bodies.first
        let notes = bodies.filter { $0 !== main }
        guard let main else { throw DocumentError.cannotOpen(directory) }

        // Footnote targets live in the notes body(ies); links to them point at that chapter file.
        var noteFile: [String: String] = [:]
        for (index, body) in notes.enumerated() {
            for section in body.descendants("section") {
                if let id = section.attribute("id") { noteFile[id] = "notes\(index).html" }
            }
        }
        let renderer = HTMLRenderer(images: images, noteFile: noteFile)
        var files: [String] = [], titles: [String] = [], outline: [Manifest.Entry] = []

        func addChapter(title: String, html: String, name fixedName: String? = nil) throws {
            let name = fixedName ?? "ch\(files.count).html"
            let page = """
            <!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/><title>\(title.htmlEscaped)</title></head>
            <body>\(html)</body></html>
            """
            try page.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
            files.append(name)
            titles.append(title)
        }

        // Body-level title/epigraph/image before the first section become an opening chapter.
        let sections = main.children("section")
        let preface = main.elements.filter { $0.name != "section" }
        if sections.isEmpty || !preface.isEmpty {
            let html = (sections.isEmpty ? main.elements : preface).map { renderer.render($0, depth: 1) }.joined()
            try addChapter(title: bookTitle ?? "Beginning", html: html)
        }
        for section in sections {
            let page = files.count
            let title = section.child("title")?.text ?? "Chapter \(page + 1)"
            try addChapter(title: title, html: renderer.render(section, depth: 1))
            outline.append(Manifest.Entry(title: title, page: page, children: subOutline(section, page: page)))
        }
        for (index, body) in notes.enumerated() {
            let title = body.child("title")?.text ?? "Notes"
            outline.append(Manifest.Entry(title: title, page: files.count, children: []))
            try addChapter(title: title, html: body.elements.map { renderer.render($0, depth: 1) }.joined(),
                           name: "notes\(index).html")
        }

        return Manifest(version: Manifest.currentVersion, title: bookTitle, chapterFiles: files, chapterTitles: titles,
                        cover: coverID.flatMap { images[$0] }, outline: outline)
    }

    private static func subOutline(_ section: XElement, page: Int) -> [Manifest.Entry] {
        section.children("section").compactMap { sub in
            guard let title = sub.child("title")?.text, !title.isEmpty else { return nil }
            return Manifest.Entry(title: title, page: page, children: subOutline(sub, page: page))
        }
    }
}

/// FB2 element tree → HTML.
private struct HTMLRenderer {
    let images: [String: String]
    /// Footnote id → chapter file holding it.
    let noteFile: [String: String]

    func render(_ element: XElement, depth: Int) -> String {
        let inner = { (d: Int) -> String in
            var out = ""
            for child in element.children {
                switch child {
                case .text(let t): out += t.htmlEscaped
                case .element(let e): out += self.render(e, depth: d)
                }
            }
            return out
        }
        switch element.name {
        case "section":
            let id = element.attribute("id").map { " id=\"\($0.htmlEscaped)\"" } ?? ""
            return "<section\(id)>\(inner(depth + 1))</section>"
        case "title": return "<h\(min(depth + 1, 6)) class=\"title\">\(element.elements.map { $0.text.htmlEscaped }.joined(separator: "<br/>"))</h\(min(depth + 1, 6))>"
        case "subtitle": return "<h5 class=\"subtitle\">\(inner(depth))</h5>"
        case "p": return "<p>\(inner(depth))</p>"
        case "emphasis": return "<em>\(inner(depth))</em>"
        case "strong": return "<strong>\(inner(depth))</strong>"
        case "strikethrough": return "<s>\(inner(depth))</s>"
        case "sub", "sup", "code": return "<\(element.name)>\(inner(depth))</\(element.name)>"
        case "empty-line": return "<br/>"
        case "epigraph": return "<blockquote class=\"epigraph\">\(inner(depth))</blockquote>"
        case "cite": return "<blockquote>\(inner(depth))</blockquote>"
        case "poem": return "<div class=\"poem\">\(inner(depth))</div>"
        case "stanza": return "<p class=\"stanza\">\(element.children("v").map { render($0, depth: depth) }.joined(separator: "<br/>"))</p>"
        case "v": return inner(depth)
        case "text-author": return "<p class=\"author\">\(inner(depth))</p>"
        case "a":
            let label = inner(depth)
            let target = element.attribute("href").map { String($0.drop { $0 == "#" }) }
            if let target, let file = noteFile[target] {
                return "<sup><a class=\"note\" href=\"\(file)#\(target.htmlEscaped)\">\(label)</a></sup>"
            }
            return element.attribute("type") == "note" ? "<sup>\(label)</sup>" : label
        case "image":
            let id = element.attribute("href").map { String($0.drop { $0 == "#" }) } ?? ""
            guard let src = images[id] else { return "" }
            return "<p class=\"image\"><img src=\"\(src.htmlEscaped)\" alt=\"\"/></p>"
        case "table", "tr", "td", "th": return "<\(element.name)>\(inner(depth))</\(element.name)>"
        default: return inner(depth)
        }
    }
}
