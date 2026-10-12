import CoreGraphics
import Foundation
import ZIPFoundation

/// Word `.docx` (Office Open XML). Converted once to HTML chapters — split at the top heading level —
/// with images, lists, tables, links, bookmarks and foot/endnotes, cached under Caches like FB2.
public final class DOCXSource: ReflowableSource, @unchecked Sendable {
    public let url: URL
    public let contentRoot: URL
    public private(set) var title: String?
    public private(set) var chapterTitles: [String] = []
    public private(set) var outline: [OutlineItem] = []

    private var chapters: [URL] = []
    private var coverURL: URL?
    private let textLock = NSLock()
    private var textCache: [Int: PageText] = [:]

    public static func canOpen(_ url: URL) -> Bool { url.pathExtension.lowercased() == "docx" }

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
        let manifest = try Self.convert(url, into: contentRoot)
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

    // MARK: Manifest

    struct Manifest: Codable {
        struct Entry: Codable {
            var title: String
            var page: Int
            var children: [Entry]
        }

        /// Bump when conversion changes so cached documents are converted again.
        static let currentVersion = 2
        var version: Int = currentVersion
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

    // MARK: Conversion

    static func convert(_ url: URL, into directory: URL) throws -> Manifest {
        let archive = try Archive(url: url, accessMode: .read)
        func data(_ path: String) -> Data? {
            guard let entry = archive[path] else { return nil }
            var out = Data()
            _ = try? archive.extract(entry, skipCRC32: true) { out.append($0) }
            return out
        }
        func xml(_ path: String) -> XElement? { data(path).flatMap { try? MiniXML.parse($0) } }

        guard let document = xml("word/document.xml"), let body = document.firstDescendant("body") else {
            throw DocumentError.cannotOpen(url)
        }

        // Relationships: images and external links.
        var relationships: [String: (target: String, external: Bool)] = [:]
        for rel in xml("word/_rels/document.xml.rels")?.descendants("Relationship") ?? [] {
            guard let id = rel.attribute("Id"), let target = rel.attribute("Target") else { continue }
            relationships[id] = (target, rel.attribute("TargetMode") == "External")
        }
        var images: [String: String] = [:]
        let imageDir = directory.appending(path: "img")
        func image(_ relID: String) -> String? {
            if let done = images[relID] { return done }
            guard let rel = relationships[relID], !rel.external else { return nil }
            let path = rel.target.hasPrefix("/") ? String(rel.target.dropFirst()) : "word/" + rel.target
            guard let bytes = data(path) else { return nil }
            try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
            let name = "img/\(images.count)-\((path as NSString).lastPathComponent)"
            guard (try? bytes.write(to: directory.appending(path: name))) != nil else { return nil }
            images[relID] = name
            return name
        }

        let styles = Styles(xml("word/styles.xml"))
        let numbering = Numbering(xml("word/numbering.xml"))
        let core = xml("docProps/core.xml")
        let docTitle = core?.firstDescendant("title")?.text.nilIfEmpty

        // Blocks with their heading levels; chapters split at the shallowest heading level used.
        let blocks = body.elements.filter { $0.name == "p" || $0.name == "tbl" || $0.name == "sdt" }
            .flatMap { $0.name == "sdt" ? ($0.child("sdtContent")?.elements ?? []) : [$0] }
        // Empty heading paragraphs (spacing) are not headings: they'd make empty chapters.
        var levels = blocks.map { $0.name == "p" && !plainText($0).isEmpty ? styles.headingLevel(of: $0) : nil }
        // No heading styles at all (common: headings typed as big bold text): infer them from formatting.
        if levels.allSatisfy({ $0 == nil }) { levels = inferredHeadingLevels(blocks) }
        let splitLevel = levels.compactMap { $0 }.min()

        // Pass 1: which chapter each block lands in, and where bookmarks are (for internal links).
        var chapterOfBlock: [Int] = []
        var chapterCount = 0
        for (i, level) in levels.enumerated() {
            if let level, level == splitLevel, i > 0, !chapterOfBlock.isEmpty, blocks[..<i].contains(where: { !isEmpty($0) }) {
                chapterCount += 1
            }
            chapterOfBlock.append(chapterCount)
        }
        var bookmarkFile: [String: String] = [:]
        for (i, block) in blocks.enumerated() {
            for mark in block.descendants("bookmarkStart") {
                if let name = mark.attribute("name") { bookmarkFile[name] = "ch\(chapterOfBlock[i]).html" }
            }
        }

        // Notes.
        let footnotes = xml("word/footnotes.xml")
        let endnotes = xml("word/endnotes.xml")
        let hasNotes = !(Self.realNotes(footnotes, "footnote").isEmpty && Self.realNotes(endnotes, "endnote").isEmpty)

        var renderer = Renderer(styles: styles, numbering: numbering, relationships: relationships,
                                bookmarkFile: bookmarkFile, notesFile: hasNotes ? "notes.html" : nil, image: image)

        // Pass 2: render chapters.
        var files: [String] = [], titles: [String] = [], outline: [Manifest.Entry] = []
        func write(_ name: String, title: String, html: String) throws {
            let page = """
            <!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/><title>\(title.htmlEscaped)</title></head>
            <body>\(html)</body></html>
            """
            try page.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }
        for chapter in 0...chapterCount {
            let indices = blocks.indices.filter { chapterOfBlock[$0] == chapter }
            renderer.reset()
            var html = ""
            var chapterTitle: String?
            for i in indices {
                html += renderer.block(blocks[i], level: levels[i])
                if let level = levels[i] {
                    let text = Self.plainText(blocks[i])
                    guard !text.isEmpty else { continue }
                    if level == splitLevel, chapterTitle == nil {
                        chapterTitle = text
                        outline.append(Manifest.Entry(title: text, page: chapter, children: []))
                    } else if level == (splitLevel ?? 0) + 1, !outline.isEmpty, outline.last!.page == chapter {
                        outline[outline.count - 1].children.append(Manifest.Entry(title: text, page: chapter, children: []))
                    }
                }
            }
            html += renderer.closeList()
            let title = chapterTitle ?? (chapter == 0 ? (docTitle ?? "Beginning") : "Section \(chapter + 1)")
            try write("ch\(chapter).html", title: title, html: html)
            files.append("ch\(chapter).html")
            titles.append(title)
        }
        if hasNotes {
            renderer.reset()
            var html = ""
            for (kind, root) in [("footnote", footnotes), ("endnote", endnotes)] {
                for note in Self.realNotes(root, kind) {
                    let id = note.attribute("id") ?? ""
                    let prefix = kind == "footnote" ? "fn" : "en"
                    let content = note.elements.map { renderer.block($0, level: nil) }.joined() + renderer.closeList()
                    html += "<section id=\"\(prefix)\(id.htmlEscaped)\" class=\"note\">\(content)</section>"
                }
            }
            outline.append(Manifest.Entry(title: "Notes", page: files.count, children: []))
            try write("notes.html", title: "Notes", html: html)
            files.append("notes.html")
            titles.append("Notes")
        }
        // Documents without headings get no outline rather than one meaningless entry.
        if splitLevel == nil && !hasNotes { outline = [] }
        let cover = images.values.sorted().first
        return Manifest(title: docTitle, chapterFiles: files, chapterTitles: titles, cover: cover, outline: outline)
    }

    /// Headings from direct formatting: short paragraphs whose text is all much larger than the body size
    /// (level 1 if ≥ 1.6×, else 2 if ≥ 1.2×), or all bold (level 3).
    static func inferredHeadingLevels(_ blocks: [XElement]) -> [Int?] {
        func runs(_ p: XElement) -> [(text: String, size: Int?, bold: Bool)] {
            p.descendants("r").compactMap { r in
                let text = r.children("t").map { t in t.children.compactMap { if case .text(let s) = $0 { s } else { nil } }.joined() }.joined()
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                let rPr = r.child("rPr")
                let bold = rPr?.child("b").map { ["true", "1", nil].contains($0.attribute("val")) } ?? false
                return (text, rPr?.child("sz")?.attribute("val").flatMap(Int.init), bold)
            }
        }
        // Body size: the size carrying the most text.
        var weight: [Int: Int] = [:]
        for block in blocks where block.name == "p" {
            for run in runs(block) { if let size = run.size { weight[size, default: 0] += run.text.count } }
        }
        let body = weight.max { $0.value < $1.value }?.key
        return blocks.map { block in
            guard block.name == "p" else { return nil }
            let parts = runs(block)
            let text = parts.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= 120, block.child("pPr")?.child("numPr") == nil else { return nil }
            if let body, parts.allSatisfy({ ($0.size ?? body) >= body * 16 / 10 }) { return 1 }
            if let body, parts.allSatisfy({ ($0.size ?? body) >= body * 12 / 10 }) { return 2 }
            if parts.allSatisfy(\.bold), !text.hasSuffix("."), !text.hasSuffix(":") { return 3 }
            return nil
        }
    }

    /// Notes with real content (ids -1/0 and type="separator"/"continuationSeparator" are layout boilerplate).
    private static func realNotes(_ root: XElement?, _ kind: String) -> [XElement] {
        (root?.children(kind) ?? []).filter { $0.attribute("type") == nil }
    }

    private static func isEmpty(_ block: XElement) -> Bool {
        plainText(block).isEmpty && block.descendants("drawing").isEmpty && block.descendants("pict").isEmpty
    }

    /// Visible text of a paragraph: runs are often split mid-word, so join `w:t` pieces without spaces.
    static func plainText(_ element: XElement) -> String {
        var out = ""
        for t in element.descendants("t") {
            for case .text(let piece) in t.children { out += piece }
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Styles & numbering

/// Paragraph style → heading level (from "heading N"/"Title" names or an outline level), following basedOn.
private struct Styles {
    private var level: [String: Int] = [:]

    init(_ root: XElement?) {
        var based: [String: String] = [:]
        var direct: [String: Int] = [:]
        for style in root?.children("style") ?? [] where style.attribute("type") == "paragraph" {
            guard let id = style.attribute("styleId") else { continue }
            let name = style.child("name")?.attribute("val")?.lowercased() ?? ""
            if name == "title" {
                direct[id] = 1
            } else if name.hasPrefix("heading "), let n = Int(name.dropFirst(8)) {
                direct[id] = n
            } else if let outline = style.child("pPr")?.child("outlineLvl")?.attribute("val").flatMap(Int.init), outline < 9 {
                direct[id] = outline + 1
            }
            if let parent = style.child("basedOn")?.attribute("val") { based[id] = parent }
        }
        for id in Set(direct.keys).union(based.keys) {
            var current: String? = id
            var hops = 0
            while let c = current, hops < 10 {
                if let l = direct[c] { level[id] = l; break }
                current = based[c]
                hops += 1
            }
        }
    }

    func headingLevel(of paragraph: XElement) -> Int? {
        let pPr = paragraph.child("pPr")
        if let outline = pPr?.child("outlineLvl")?.attribute("val").flatMap(Int.init), outline < 9 { return outline + 1 }
        guard let style = pPr?.child("pStyle")?.attribute("val") else { return nil }
        if let l = level[style] { return l }
        // Documents without styles.xml still use the built-in ids.
        let lower = style.lowercased()
        if lower == "title" { return 1 }
        if lower.hasPrefix("heading"), let n = Int(lower.dropFirst(7)) { return n }
        return nil
    }
}

/// numId + level → ordered or bullet list.
private struct Numbering {
    private var ordered: [String: [Int: Bool]] = [:]

    init(_ root: XElement?) {
        var abstract: [String: [Int: Bool]] = [:]
        for def in root?.children("abstractNum") ?? [] {
            guard let id = def.attribute("abstractNumId") else { continue }
            var levels: [Int: Bool] = [:]
            for lvl in def.children("lvl") {
                let ilvl = lvl.attribute("ilvl").flatMap(Int.init) ?? 0
                let format = lvl.child("numFmt")?.attribute("val") ?? "bullet"
                levels[ilvl] = format != "bullet" && format != "none"
            }
            abstract[id] = levels
        }
        for num in root?.children("num") ?? [] {
            guard let id = num.attribute("numId"), let abstractID = num.child("abstractNumId")?.attribute("val") else { continue }
            ordered[id] = abstract[abstractID]
        }
    }

    func isOrdered(numID: String, level: Int) -> Bool { ordered[numID]?[level] ?? false }
}

// MARK: - Rendering

private struct Renderer {
    let styles: Styles
    let numbering: Numbering
    let relationships: [String: (target: String, external: Bool)]
    let bookmarkFile: [String: String]
    let notesFile: String?
    let image: (String) -> String?

    /// Open list tags, innermost last ("ul"/"ol").
    private var listStack: [String] = []

    init(styles: Styles, numbering: Numbering, relationships: [String: (target: String, external: Bool)],
         bookmarkFile: [String: String], notesFile: String?, image: @escaping (String) -> String?) {
        self.styles = styles
        self.numbering = numbering
        self.relationships = relationships
        self.bookmarkFile = bookmarkFile
        self.notesFile = notesFile
        self.image = image
    }

    mutating func reset() { listStack = [] }

    mutating func closeList() -> String {
        defer { listStack = [] }
        return listStack.reversed().map { "</li></\($0)>" }.joined()
    }

    mutating func block(_ element: XElement, level: Int?) -> String {
        switch element.name {
        case "p": return paragraph(element, level: level)
        case "tbl": return closeList() + table(element)
        case "sdt": return (element.child("sdtContent")?.elements ?? []).map { block($0, level: nil) }.joined()
        default: return ""
        }
    }

    private mutating func paragraph(_ p: XElement, level: Int?) -> String {
        let content = inline(p)
        let pPr = p.child("pPr")
        if let numPr = pPr?.child("numPr"), level == nil,
           let numID = numPr.child("numId")?.attribute("val"), numID != "0" {
            let depth = numPr.child("ilvl")?.attribute("val").flatMap(Int.init) ?? 0
            let tag = numbering.isOrdered(numID: numID, level: depth) ? "ol" : "ul"
            var out = ""
            while listStack.count > depth + 1 { out += "</li></\(listStack.removeLast())>" }
            if listStack.count == depth + 1 {
                if listStack.last != tag {
                    out += "</li></\(listStack.removeLast())><\(tag)><li>"
                    listStack.append(tag)
                } else {
                    out += "</li><li>"
                }
            } else {
                while listStack.count < depth + 1 {
                    out += "<\(tag)><li>"
                    listStack.append(tag)
                }
            }
            return out + content
        }
        let close = closeList()
        if let level {
            let h = min(max(level, 1), 6)
            return close + "<h\(h)>\(content)</h\(h)>"
        }
        let align = pPr?.child("jc")?.attribute("val")
        let style = align == "center" ? " style=\"text-align:center\"" : (align == "right" || align == "end" ? " style=\"text-align:right\"" : "")
        if content.isEmpty { return close }
        return close + "<p\(style)>\(content)</p>"
    }

    private func table(_ tbl: XElement) -> String {
        var rows = ""
        for tr in tbl.children("tr") {
            var cells = ""
            for tc in tr.children("tc") {
                var inner = Renderer(styles: styles, numbering: numbering, relationships: relationships,
                                     bookmarkFile: bookmarkFile, notesFile: notesFile, image: image)
                let span = tc.child("tcPr")?.child("gridSpan")?.attribute("val").map { " colspan=\"\($0)\"" } ?? ""
                let html = tc.elements.map { inner.block($0, level: nil) }.joined() + inner.closeList()
                cells += "<td\(span)>\(html)</td>"
            }
            rows += "<tr>\(cells)</tr>"
        }
        return "<table>\(rows)</table>"
    }

    /// Runs, links, images and note references inside a paragraph.
    private func inline(_ element: XElement) -> String {
        var out = ""
        for child in element.elements {
            switch child.name {
            case "r": out += run(child)
            case "hyperlink":
                let inner = inline(child)
                if let id = child.attribute("id"), let rel = relationships[id], rel.external {
                    out += "<a href=\"\(rel.target.htmlEscaped)\">\(inner)</a>"
                } else if let anchor = child.attribute("anchor"), let file = bookmarkFile[anchor] {
                    out += "<a href=\"\(file)#\(anchor.htmlEscaped)\">\(inner)</a>"
                } else {
                    out += inner
                }
            case "bookmarkStart":
                if let name = child.attribute("name"), !name.hasPrefix("_GoBack") { out += "<a id=\"\(name.htmlEscaped)\"></a>" }
            case "ins", "smartTag", "customXml", "fldSimple", "sdt", "sdtContent": out += inline(child)
            default: break
            }
        }
        return out
    }

    private func run(_ r: XElement) -> String {
        var text = ""
        for part in r.elements {
            switch part.name {
            case "t":
                var s = ""
                for case .text(let t) in part.children { s += t }
                text += s.htmlEscaped
            case "tab": text += " "
            case "br", "cr": text += part.attribute("type") == "page" ? "" : "<br/>"
            case "noBreakHyphen": text += "‑"
            case "sym": text += ""
            case "drawing", "pict", "object":
                for blip in part.descendants("blip") + part.descendants("imagedata") {
                    if let id = blip.attribute("embed") ?? blip.attribute("id"), let src = image(id) {
                        text += "<img src=\"\(src.htmlEscaped)\" alt=\"\"/>"
                    }
                }
            case "footnoteReference", "endnoteReference":
                guard let notesFile, let id = part.attribute("id") else { continue }
                let prefix = part.name == "footnoteReference" ? "fn" : "en"
                let mark = part.name == "footnoteReference" ? id : "e\(id)"
                text += "<sup><a class=\"note\" href=\"\(notesFile)#\(prefix)\(id.htmlEscaped)\">\(mark.htmlEscaped)</a></sup>"
            default: break
            }
        }
        guard !text.isEmpty else { return "" }
        let rPr = r.child("rPr")
        if rPr?.child("vanish") != nil { return "" }   // hidden text
        func on(_ name: String) -> Bool {
            guard let e = rPr?.child(name) else { return false }
            let v = e.attribute("val")
            return v == nil || v == "true" || v == "1" || (name == "u" && v != "none" && v != "0" && v != "false")
        }
        if on("b") { text = "<strong>\(text)</strong>" }
        if on("i") { text = "<em>\(text)</em>" }
        if on("u") { text = "<u>\(text)</u>" }
        if on("strike") || on("dstrike") { text = "<s>\(text)</s>" }
        switch rPr?.child("vertAlign")?.attribute("val") {
        case "superscript": text = "<sup>\(text)</sup>"
        case "subscript": text = "<sub>\(text)</sub>"
        default: break
        }
        return text
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
