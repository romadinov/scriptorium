import CCHMLib
import CoreGraphics
import Foundation

/// Microsoft Compiled HTML Help (`.chm`) via CHMLib. Unpacked once into Caches (HTML re-encoded to
/// UTF-8); chapters follow the table of contents (`.hhc`), falling back to all pages in name order.
public final class CHMSource: ReflowableSource, @unchecked Sendable {
    public let url: URL
    public let contentRoot: URL
    public private(set) var title: String?
    public private(set) var chapterTitles: [String] = []
    public private(set) var outline: [OutlineItem] = []

    private var chapters: [URL] = []
    private var coverURL: URL?
    private let textLock = NSLock()
    private var textCache: [Int: PageText] = [:]

    struct Manifest: Codable {
        struct Entry: Codable {
            var title: String
            var page: Int?
            var children: [Entry]
        }

        var title: String?
        var chapters: [String]
        var chapterTitles: [String]
        var outline: [Entry]
        var cover: String?
    }

    public init(url: URL) throws {
        self.url = url
        contentRoot = BookCache.directory(for: url, kind: "Books")
        let manifestURL = contentRoot.appending(path: ".chm-manifest.json")
        if let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            apply(manifest)
            return
        }
        try? FileManager.default.removeItem(at: contentRoot)
        try FileManager.default.createDirectory(at: contentRoot, withIntermediateDirectories: true)
        let manifest = try Self.unpack(url, into: contentRoot)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        apply(manifest)
    }

    private func apply(_ manifest: Manifest) {
        title = manifest.title
        chapters = manifest.chapters.map { contentRoot.appending(path: $0) }
        chapterTitles = manifest.chapterTitles
        coverURL = manifest.cover.map { contentRoot.appending(path: $0) }
        func items(_ entries: [Manifest.Entry]) -> [OutlineItem] {
            entries.map { OutlineItem(title: $0.title, pageIndex: $0.page, children: items($0.children)) }
        }
        outline = items(manifest.outline)
    }

    // MARK: PageSource

    public var pageCount: Int { chapters.count }

    public func pageSize(at index: Int) -> CGSize { CGSize(width: 800, height: 1100) }

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

    // MARK: Unpacking

    private final class Collector {
        var paths: [String] = []
    }

    static func unpack(_ url: URL, into root: URL) throws -> Manifest {
        guard let handle = url.path.withCString({ chm_open($0) }) else { throw DocumentError.cannotOpen(url) }
        defer { chm_close(handle) }

        // 1. List normal files (skips internal "#…"/"$…" streams).
        let collector = Collector()
        let context = Unmanaged.passUnretained(collector).toOpaque()
        _ = chm_enumerate(handle, CHM_ENUMERATE_NORMAL | CHM_ENUMERATE_FILES, { _, info, context in
            guard let info, let context else { return CHM_ENUMERATOR_CONTINUE }
            let path = withUnsafeBytes(of: info.pointee.path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue().paths.append(path)
            return CHM_ENUMERATOR_CONTINUE
        }, context)

        // 2. Extract; HTML-like files are converted to UTF-8 as they are written.
        var htmlFiles: [String] = []
        var images: [(path: String, size: Int)] = []
        var hhc: (path: String, text: String)?
        for path in collector.paths {
            guard let data = read(handle, path) else { continue }
            let relative = String(path.drop { $0 == "/" })
            guard !relative.isEmpty, !relative.contains("..") else { continue }
            let target = root.appending(path: relative)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let ext = target.pathExtension.lowercased()
            if ["htm", "html", "xhtml", "hhc", "hhk"].contains(ext) {
                let text = utf8HTML(data)
                try Data(text.utf8).write(to: target)
                if ext == "hhc", hhc == nil { hhc = (relative, text) }
                if ["htm", "html", "xhtml"].contains(ext) { htmlFiles.append(relative) }
            } else {
                try data.write(to: target)
                if ["jpg", "jpeg", "png", "gif"].contains(ext) { images.append((relative, data.count)) }
            }
        }

        // 3. Table of contents → outline + chapter order.
        var chapterPaths: [String] = []
        var chapterTitles: [String] = []
        var outline: [Manifest.Entry] = []
        if let hhc {
            let base = (hhc.path as NSString).deletingLastPathComponent
            let tree = SiteMap.parse(hhc.text)
            func walk(_ nodes: [SiteMap.Node]) -> [Manifest.Entry] {
                nodes.map { node in
                    var page: Int?
                    if let local = node.local {
                        let file = normalise(local, base: base)
                        if FileManager.default.fileExists(atPath: root.appending(path: file).path) {
                            if let existing = chapterPaths.firstIndex(of: file) {
                                page = existing
                            } else {
                                chapterPaths.append(file)
                                chapterTitles.append(node.name)
                                page = chapterPaths.count - 1
                            }
                        }
                    }
                    return Manifest.Entry(title: node.name, page: page, children: walk(node.children))
                }
            }
            outline = walk(tree)
        }
        if chapterPaths.isEmpty {
            chapterPaths = htmlFiles.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            chapterTitles = chapterPaths.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        }
        guard !chapterPaths.isEmpty else { throw DocumentError.cannotOpen(url) }

        let title = systemTitle(handle) ?? outline.first?.title
        let cover = images.filter { $0.size > 8_000 }.first?.path
        return Manifest(title: title, chapters: chapterPaths, chapterTitles: chapterTitles, outline: outline, cover: cover)
    }

    private static func read(_ handle: OpaquePointer, _ path: String) -> Data? {
        var info = chmUnitInfo()
        guard chm_resolve_object(handle, path, &info) == CHM_RESOLVE_SUCCESS, info.length < 200_000_000 else { return nil }
        if info.length == 0 { return Data() }
        var data = Data(count: Int(info.length))
        let read = data.withUnsafeMutableBytes { buffer in
            chm_retrieve_object(handle, &info, buffer.bindMemory(to: UInt8.self).baseAddress, 0, LONGINT64(info.length))
        }
        return read == LONGINT64(info.length) ? data : nil
    }

    /// Title from the #SYSTEM stream: a version word, then records of (code, length, data); code 3 is the title.
    private static func systemTitle(_ handle: OpaquePointer) -> String? {
        guard let data = read(handle, "/#SYSTEM"), data.count > 4 else { return nil }
        var offset = 4
        while offset + 4 <= data.count {
            let code = Int(data[offset]) | Int(data[offset + 1]) << 8
            let length = Int(data[offset + 2]) | Int(data[offset + 3]) << 8
            offset += 4
            guard offset + length <= data.count else { break }
            if code == 3 {
                let bytes = data[offset..<(offset + length)].prefix { $0 != 0 }
                let title = decode(Data(bytes), charset: nil).trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? nil : title
            }
            offset += length
        }
        return nil
    }

    /// "Lib/Page.htm#anchor" relative to the .hhc's folder → archive-relative path without the anchor.
    private static func normalise(_ local: String, base: String) -> String {
        var path = local.split(separator: "#", maxSplits: 1).first.map(String.init) ?? local
        if let range = path.range(of: "::") { path = String(path[range.upperBound...]) }   // "file.chm::/x.htm"
        path = path.replacingOccurrences(of: "\\", with: "/")
        path = path.removingPercentEncoding ?? path
        let joined = path.hasPrefix("/") ? String(path.dropFirst()) : (base.isEmpty ? path : base + "/" + path)
        return (joined as NSString).standardizingPath
    }

    // MARK: Encodings

    /// CHM pages are usually in a legacy code page; convert to UTF-8 and say so in the page.
    static func utf8HTML(_ data: Data) -> String {
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        let declared = head.range(of: "charset\\s*=\\s*[\"']?([A-Za-z0-9_-]+)", options: [.regularExpression, .caseInsensitive])
            .map { String(head[$0]).components(separatedBy: "=").last!.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
        var text = decode(data, charset: declared)
        text = text.replacingOccurrences(of: "charset\\s*=\\s*[\"']?[A-Za-z0-9_-]+", with: "charset=utf-8",
                                         options: [.regularExpression, .caseInsensitive])
        return text
    }

    static func decode(_ data: Data, charset: String?) -> String {
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Cyrillic text in Windows-1251 is almost all bytes C0–FF; Western text in Windows-1252 has only
        // the odd accented letter. Decide by the share of such bytes among all letters.
        let sample = data.prefix(8192)
        let high = sample.filter { $0 >= 0xC0 }.count
        let ascii = sample.filter { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }.count
        let encoding: String.Encoding = Double(high) > Double(high + ascii) * 0.3 ? .windowsCP1251 : .windowsCP1252
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Parser for HTML Help sitemaps (.hhc): nested <UL><LI><OBJECT type="text/sitemap"><param …></OBJECT>.
/// Real files are tag soup (unclosed <LI>, mixed case), so this works on a tag stream, not XML.
enum SiteMap {
    struct Node {
        var name: String
        var local: String?
        var children: [Node] = []
    }

    static func parse(_ html: String) -> [Node] {
        let tag = try! NSRegularExpression(pattern: "<\\s*(/?)\\s*(ul|object|param)\\b([^>]*)>", options: .caseInsensitive)
        let nameAttr = try! NSRegularExpression(pattern: "name\\s*=\\s*[\"']([^\"']*)[\"']", options: .caseInsensitive)
        let valueAttr = try! NSRegularExpression(pattern: "value\\s*=\\s*[\"']([^\"']*)[\"']", options: .caseInsensitive)
        let ns = html as NSString

        // Stack of child lists; each <UL> opens a list under the most recent node of the enclosing list.
        var stack: [[Node]] = [[]]
        var current: Node?
        func attribute(_ regex: NSRegularExpression, _ text: String) -> String? {
            let tns = text as NSString
            return regex.firstMatch(in: text, range: NSRange(location: 0, length: tns.length)).map { tns.substring(with: $0.range(at: 1)) }
        }
        func closeList() {
            guard stack.count > 1 else { return }
            let children = stack.removeLast()
            if !stack[stack.count - 1].isEmpty {
                stack[stack.count - 1][stack[stack.count - 1].count - 1].children += children
            } else {
                stack[stack.count - 1] += children
            }
        }

        for match in tag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let closing = ns.substring(with: match.range(at: 1)) == "/"
            let name = ns.substring(with: match.range(at: 2)).lowercased()
            let attrs = ns.substring(with: match.range(at: 3))
            switch (name, closing) {
            case ("ul", false): stack.append([])
            case ("ul", true): closeList()
            case ("object", false): current = Node(name: "")
            case ("param", _):
                guard current != nil, let key = attribute(nameAttr, attrs)?.lowercased(), let value = attribute(valueAttr, attrs) else { break }
                if key == "name", current!.name.isEmpty { current!.name = decodeEntities(value) }
                if key == "local", current!.local == nil { current!.local = value }
            case ("object", true):
                if let node = current, !node.name.isEmpty { stack[stack.count - 1].append(node) }
                current = nil
            default: break
            }
        }
        while stack.count > 1 { closeList() }
        return stack[0]
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
