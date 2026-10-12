import CoreGraphics
import Foundation

/// Kindle Format 8 (`.azw3`, DRM-free). The PalmDB container holds compressed markup that is rebuilt from
/// skeletons and fragments into one HTML file per part, CSS flows, and image records; the NCX index gives
/// the contents. Converted once into Caches like FB2/DOCX. Follows the layout documented on the MobileRead
/// wiki and implemented by calibre's KF8 reader.
public final class AZW3Source: ReflowableSource, @unchecked Sendable {
    public let url: URL
    public let contentRoot: URL
    public private(set) var title: String?
    public private(set) var chapterTitles: [String] = []
    public private(set) var outline: [OutlineItem] = []

    private var chapters: [URL] = []
    private var coverURL: URL?
    private let textLock = NSLock()
    private var textCache: [Int: PageText] = [:]

    public enum Failure: LocalizedError {
        case drm, notKF8, unsupportedCompression, damaged(String)

        public var errorDescription: String? {
            switch self {
            case .drm: "This Kindle book is DRM-protected. Only DRM-free AZW3 files can be opened."
            case .notKF8: "This is an older MOBI-format Kindle file, which isn't supported yet."
            case .unsupportedCompression: "This Kindle file uses a compression Scriptorium can't read yet."
            case .damaged(let what): "The Kindle file is damaged (\(what))."
            }
        }
    }

    public static func canOpen(_ url: URL) -> Bool { url.pathExtension.lowercased() == "azw3" }

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
        let manifest = try KF8Converter(data: Data(contentsOf: url, options: .mappedIfSafe)).convert(into: contentRoot)
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

        static let currentVersion = 1
        var version = currentVersion
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
}

// MARK: - Converter

private let nullIndex = 0xFFFF_FFFF

struct KF8Converter {
    let records: [Data]

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 86 else { throw AZW3Source.Failure.damaged("too short") }
        let count = Int(bytes.be16(76))
        guard 78 + count * 8 <= bytes.count else { throw AZW3Source.Failure.damaged("record list") }
        let offsets = (0..<count).map { Int(bytes.be32(78 + $0 * 8)) } + [bytes.count]
        var records: [Data] = []
        for i in 0..<count {
            let start = offsets[i], end = max(start, min(offsets[i + 1], bytes.count))
            guard start <= bytes.count else { throw AZW3Source.Failure.damaged("record offsets") }
            records.append(Data(bytes[start..<end]))
        }
        self.records = records
    }

    // MARK: Headers

    struct Header {
        var compression = 0, textRecords = 0, encryption = 0, codepage = 1252
        var extraFlags = 0, mobiVersion = 0, firstImage = nullIndex
        var fdst = nullIndex, fdstCount = 0, skel = nullIndex, frag = nullIndex, ncx = nullIndex
        var fullName = ""
        var exth: [Int: [Data]] = [:]

        var isUTF8: Bool { codepage == 65001 }

        init(_ record: Data) {
            let b = [UInt8](record)
            guard b.count >= 16 else { return }
            compression = Int(b.be16(0))
            textRecords = Int(b.be16(8))
            encryption = Int(b.be16(12))
            guard b.count >= 0x84, b[16..<20].elementsEqual("MOBI".utf8) else { return }
            let length = Int(b.be32(20))
            codepage = Int(b.be32(28))
            if length >= 0xE4, length <= 500, b.count >= 0xF4 { extraFlags = Int(b.be16(0xF2)) }
            let titleOffset = Int(b.be32(0x54)), titleLength = Int(b.be32(0x58))
            if titleOffset + titleLength <= b.count {
                fullName = String(decoding: b[titleOffset..<titleOffset + titleLength], as: UTF8.self)
            }
            mobiVersion = Int(b.be32(0x68))
            firstImage = Int(b.be32(0x6C))
            if b.count >= 0xF8 { ncx = Int(b.be32(0xF4)) }
            if mobiVersion == 8, b.count >= 0xF8 + 16 {
                frag = Int(b.be32(0xF8))
                skel = Int(b.be32(0xFC))
                fdst = Int(b.be32(0xC0))
                fdstCount = Int(b.be32(0xC4))
                if fdstCount <= 1 { fdst = nullIndex }
            }
            // EXTH metadata.
            let exthStart = 16 + length
            if Int(b.be32(0x80)) & 0x40 != 0, exthStart + 12 <= b.count, b[exthStart..<exthStart + 4].elementsEqual("EXTH".utf8) {
                var pos = exthStart + 12
                for _ in 0..<Int(b.be32(exthStart + 8)) {
                    guard pos + 8 <= b.count else { break }
                    let type = Int(b.be32(pos)), size = Int(b.be32(pos + 4))
                    guard size >= 8, pos + size <= b.count else { break }
                    exth[type, default: []].append(Data(b[pos + 8..<pos + size]))
                    pos += size
                }
            }
        }

        func exthInt(_ type: Int) -> Int? {
            guard let d = exth[type]?.first, d.count >= 4 else { return nil }
            return Int([UInt8](d).be32(0))
        }

        func exthString(_ type: Int) -> String? {
            exth[type]?.first.map { String(decoding: $0, as: UTF8.self) }
        }
    }

    // MARK: Convert

    func convert(into directory: URL) throws -> AZW3Source.Manifest {
        guard let first = records.first else { throw AZW3Source.Failure.damaged("no records") }
        var header = Header(first)
        if header.encryption != 0 { throw AZW3Source.Failure.drm }

        // KF8 sections start at the KF8 header record: record 0 for standalone files, or the record after
        // BOUNDARY in joint MOBI6+KF8 files.
        var kf8Base = 0
        var resourceRanges: [(Int, Int)] = []
        if header.mobiVersion == 8, header.skel != nullIndex {
            let firstResource = header.firstImage == nullIndex ? header.textRecords + 1 : header.firstImage
            resourceRanges = [(firstResource, records.count)]
        } else if let k8 = header.exthInt(121), k8 != nullIndex, k8 > 0, k8 < records.count,
                  records[k8 - 1] == Data("BOUNDARY".utf8) {
            let mobi6 = header
            header = Header(records[k8])
            header.exth = header.exth.isEmpty ? mobi6.exth : header.exth
            if header.encryption != 0 { throw AZW3Source.Failure.drm }
            guard header.skel != nullIndex else { throw AZW3Source.Failure.notKF8 }
            kf8Base = k8
            let first6 = mobi6.firstImage == nullIndex ? mobi6.textRecords + 1 : mobi6.firstImage
            let first8 = header.firstImage == nullIndex ? header.textRecords + k8 + 1 : header.firstImage + k8
            resourceRanges = [(first6, k8 - 1), (first8, records.count)]
        } else {
            throw AZW3Source.Failure.notKF8
        }
        func kf8(_ index: Int) -> Data? {
            let i = kf8Base + index
            return records.indices.contains(i) ? records[i] : nil
        }

        // Text.
        let raw = try text(header: header, firstRecord: kf8Base + 1)
        let decode: (Data) -> String = { data in
            header.isUTF8 ? String(decoding: data, as: UTF8.self) : (String(data: data, encoding: .windowsCP1252) ?? "")
        }

        // Flows (0 = the HTML text, others CSS/SVG).
        var flowRanges = [(0, raw.count)]
        if header.fdst != nullIndex, let fdst = kf8(header.fdst), fdst.prefix(4) == Data("FDST".utf8) {
            let b = [UInt8](fdst)
            let start = Int(b.be32(4)), n = Int(b.be32(8))
            flowRanges = (0..<n).compactMap { i in
                let at = start + i * 8
                guard at + 8 <= b.count else { return nil }
                return (Int(b.be32(at)), Int(b.be32(at + 4)))
            }
        }
        let flows = flowRanges.map { (s, e) in raw[min(s, raw.count)..<min(max(s, e), raw.count)] }
        let text = Data(flows.first ?? Data())

        // Index tables.
        let skeletons = try readIndex(header.skel, kf8: kf8, header: header).table
        let fragTable = try readIndex(header.frag, kf8: kf8, header: header)
        struct Fragment { var insertPos: Int, aid: String, start: Int, length: Int }
        let fragments: [Fragment] = fragTable.table.map { entry in
            let aidText = entry.tags[2].flatMap { fragTable.cncx[$0.first ?? -1] } ?? ""
            return Fragment(insertPos: Int(entry.name) ?? 0, aid: aidText,
                            start: entry.tags[6]?.first ?? 0, length: entry.tags[6]?.dropFirst().first ?? 0)
        }

        // Rebuild parts: each skeleton with its fragments inserted.
        struct Part { var html: Data, start: Int, end: Int }
        var parts: [Part] = []
        var fragIndex = 0
        for skeleton in skeletons {
            let count = skeleton.tags[1]?.first ?? 0
            guard let pos = skeleton.tags[6], pos.count >= 2 else { continue }
            let skelStart = pos[0], skelLength = pos[1]
            var base = skelStart + skelLength
            guard skelStart <= text.count, base <= text.count else { throw AZW3Source.Failure.damaged("skeleton") }
            var html = Data(text[skelStart..<base])
            for _ in 0..<count {
                guard fragIndex < fragments.count else { break }
                let frag = fragments[fragIndex]
                let end = min(base + frag.length, text.count)
                let piece = text[min(base, text.count)..<end]
                var insert = frag.insertPos - skelStart
                if insert < 0 || insert > html.count || !Self.isBetweenTags(html, insert) {
                    // Bad insert position in the div table: find the tag with this fragment's aid.
                    let aid = frag.aid.count > 14 ? String(frag.aid.dropFirst(12).dropLast(2)) : frag.aid
                    if let end = Self.endOfTag(withAID: aid, in: html) { insert = end + 1 + frag.start }
                }
                insert = min(max(0, insert), html.count)
                html.insert(contentsOf: piece, at: insert)
                base += frag.length
                fragIndex += 1
            }
            parts.append(Part(html: html, start: skelStart, end: base))
        }
        guard !parts.isEmpty else { throw AZW3Source.Failure.damaged("no text") }
        let fileName = { (i: Int) in String(format: "part%04d.html", i) }

        // Position (fid, offset) → part and anchor.
        func part(at pos: Int) -> Int? { parts.firstIndex { pos >= $0.start && pos < $0.end } }
        var linkedAIDs = Set<String>()
        func anchor(at pos: Int) -> (part: Int, id: String)? {
            guard let p = part(at: pos) else { return nil }
            let block = [UInt8](parts[p].html)
            var n = min(max(0, pos - parts[p].start), block.count)
            if let gt = block[n...].firstIndex(of: UInt8(ascii: ">")) {
                let lt = block[n...].firstIndex(of: UInt8(ascii: "<"))
                if lt == n || lt == nil || gt < lt! { n = gt + 1 }
            }
            let prefix = String(decoding: block[..<n], as: UTF8.self)
            for tag in Self.tagsReversed(prefix) {
                if let id = Self.attribute(["id", "ID", "name", "NAME"], in: tag) { return (p, id) }
                if let aid = Self.attribute(["aid", "AID"], in: tag) {
                    linkedAIDs.insert(aid)
                    return (p, "aid-" + aid)
                }
            }
            return (p, "")
        }
        func target(fid: Int, offset: Int) -> String? {
            guard fragments.indices.contains(fid), let a = anchor(at: fragments[fid].insertPos + offset) else { return nil }
            return fileName(a.part) + (a.id.isEmpty ? "" : "#" + a.id)
        }

        // Resources.
        let imageDir = directory.appending(path: "img")
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        var resources: [String?] = []
        var counter = 0
        for (start, end) in resourceRanges where start < end {
            for i in max(0, start)..<min(end, records.count) {
                counter += 1
                let data = records[i]
                guard let ext = Self.imageType(data) else { resources.append(nil); continue }
                let name = String(format: "img/%05d.%@", counter, ext)
                try data.write(to: directory.appending(path: name))
                resources.append(name)
            }
        }
        func resource(_ base32: String) -> String? {
            guard let n = Int(base32, radix: 32), n >= 1, n <= resources.count else { return nil }
            return resources[n - 1]
        }

        // CSS/SVG flows → files.
        let cssDir = directory.appending(path: "css")
        try FileManager.default.createDirectory(at: cssDir, withIntermediateDirectories: true)
        var flowFiles: [Int: String] = [:]
        var inlineFlows: [Int: String] = [:]
        for j in flows.indices.dropFirst() {
            var flow = decode(Data(flows[j]))
            flow = Self.replace(#"kindle:embed:([0-9A-V]+)(\?mime=[^)'"]*)?"#, in: flow) { m in
                resource(m[1]).map { "../" + $0 } ?? ""
            }
            flow = Self.replace(#"kindle:flow:([0-9A-V]+)\?mime=text/css[^)'"]*"#, in: flow) { m in
                Int(m[1], radix: 32).map { String(format: "%04d.css", $0) } ?? ""
            }
            if flow.range(of: "<svg", options: .caseInsensitive) != nil {
                inlineFlows[j] = flow                               // SVG: inline where referenced
            } else if flow.contains("[CDATA[") {
                inlineFlows[j] = "<style type=\"text/css\">\n\(flow)\n</style>"
            } else {
                let name = String(format: "css/%04d.css", j)
                try flow.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
                flowFiles[j] = name
            }
        }

        // NCX → titles and outline. Resolve anchors before rewriting parts so linked aids are known.
        let ncx = try readIndex(header.ncx, kf8: kf8, header: header)
        struct NCXEntry { var text: String, level: Int, parent: Int, part: Int }
        var ncxEntries: [NCXEntry] = []
        for entry in ncx.table {
            let text = entry.tags[3].flatMap { ncx.cncx[$0.first ?? -1] } ?? entry.name
            let level = entry.tags[4]?.first ?? 0
            let parent = entry.tags[21]?.first ?? -1
            var partIndex: Int?
            if let pf = entry.tags[6], pf.count >= 2, fragments.indices.contains(pf[0]) {
                partIndex = anchor(at: fragments[pf[0]].insertPos + pf[1])?.part
            } else if let pos = entry.tags[1]?.first {
                partIndex = part(at: pos)
            }
            ncxEntries.append(NCXEntry(text: Self.unescape(text), level: level, parent: parent, part: partIndex ?? -1))
        }

        // Rewrite parts: internal links first (anchors are looked up in the original markup, so collect
        // all rewritten parts before replacing any), then images, flows, kindlegen attributes.
        let files = parts.indices.map(fileName)
        let linked: [String] = parts.map { p in
            Self.replace(#"(['"])kindle:pos:fid:([0-9A-V]+):off:([0-9A-V]+)[^'"]*(['"])"#, in: decode(p.html)) { m in
                let t = Int(m[2], radix: 32).flatMap { fid in Int(m[3], radix: 32).flatMap { target(fid: fid, offset: $0) } }
                return "\"" + (t ?? "#").replacingOccurrences(of: "\"", with: "&quot;") + "\""
            }
        }
        for (i, linkedHTML) in linked.enumerated() {
            var html = linkedHTML
            // aid attributes → ids only where something links to them (tags that already have an id keep it).
            html = Self.replace(#"<[^>]*\s[ac]id\s*=[^>]*>"#, in: html) { m in
                let tag = m[0]
                let hasID = tag.range(of: #"\sid\s*="#, options: .regularExpression) != nil
                return Self.replace(#"\s([ac]id)\s*=\s*['"]([^'"]*)['"]"#, in: tag) { a in
                    a[1] == "aid" && !hasID && linkedAIDs.contains(a[2]) ? " id=\"aid-\(a[2])\"" : ""
                }
            }
            html = Self.replace(#"\sdata-AmznPageBreak=['"]([^'"]*)['"]"#, in: html) { m in " style=\"page-break-after:\(m[1])\"" }
            html = Self.replace(#"(['"(])kindle:embed:([0-9A-V]+)[^'")]*(['")])"#, in: html) { m in
                m[1] + (resource(m[2]) ?? "") + m[3]
            }
            html = Self.replace(#"<[^>]*['"]kindle:flow:([0-9A-V]+)\?mime=([^'"]+)['"][^>]*>"#, in: html) { m in
                guard let n = Int(m[1], radix: 32) else { return "" }
                if let inline = inlineFlows[n] { return inline }
                guard let file = flowFiles[n] else { return "" }
                return Self.replace(#"kindle:flow:[0-9A-V]+\?mime=[^'"]+"#, in: m[0]) { _ in file }
            }
            html = Self.replace(#"<\?xml[^>]*\?>"#, in: html) { _ in "" }
            html = Self.replace(#"<meta[^>]*charset[^>]*>"#, in: html) { _ in "" }
            if let head = html.range(of: #"<head[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: "<meta charset=\"utf-8\"/>", at: head.upperBound)
            }
            html = html.replacingOccurrences(of: "viewbox=", with: "viewBox=")
                .replacingOccurrences(of: "preserveaspectratio=", with: "preserveAspectRatio=")
            try html.write(to: directory.appending(path: files[i]), atomically: true, encoding: .utf8)
        }

        // Titles: the first contents entry pointing into each part.
        var titles: [String] = []
        for i in parts.indices {
            let t = ncxEntries.first { $0.part == i }?.text
                ?? Self.firstHeading(in: directory.appending(path: files[i]))
            titles.append(t ?? "Section \(i + 1)")
        }
        // Outline from the NCX tree.
        func children(of parent: Int) -> [AZW3Source.Manifest.Entry] {
            ncxEntries.enumerated().filter { $0.element.parent == parent && $0.element.part >= 0 }.map { index, e in
                AZW3Source.Manifest.Entry(title: e.text, page: e.part, children: children(of: index))
            }
        }
        let outline = children(of: -1)

        let title = header.exthString(503) ?? (header.fullName.isEmpty ? nil : header.fullName)
        let cover = header.exthInt(201).flatMap { $0 < resources.count ? resources[$0] : nil }
        return AZW3Source.Manifest(title: title, chapterFiles: files, chapterTitles: titles, cover: cover, outline: outline)
    }

    // MARK: Text records

    private func text(header: Header, firstRecord: Int) throws -> Data {
        guard header.compression == 1 || header.compression == 2 else { throw AZW3Source.Failure.unsupportedCompression }
        var out = Data()
        let last = min(firstRecord + header.textRecords, records.count)
        guard firstRecord < last else { return out }
        for i in firstRecord..<last {
            var bytes = [UInt8](records[i])
            bytes.removeLast(min(bytes.count, Self.trailingSize(bytes, flags: header.extraFlags)))
            out.append(contentsOf: header.compression == 2 ? Self.palmDOC(bytes) : bytes)
        }
        return out
    }

    static func trailingSize(_ data: [UInt8], flags: Int) -> Int {
        var num = 0
        var f = flags >> 1
        while f != 0 {
            if f & 1 != 0 {
                var size = data.count - num, bit = 0, result = 0
                while size > 0 {
                    let v = Int(data[size - 1])
                    result |= (v & 0x7F) << bit
                    bit += 7
                    size -= 1
                    if v & 0x80 != 0 || bit >= 28 { break }
                }
                num += result
            }
            f >>= 1
        }
        if flags & 1 != 0, data.count - num - 1 >= 0 { num += Int(data[data.count - num - 1] & 0x3) + 1 }
        return num
    }

    /// PalmDOC LZ77.
    static func palmDOC(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 2)
        var i = 0
        while i < input.count {
            let c = input[i]
            i += 1
            switch c {
            case 0x01...0x08:
                let n = Int(c)
                out.append(contentsOf: input[i..<min(i + n, input.count)])
                i += n
            case 0x80...0xBF:
                guard i < input.count else { break }
                let pair = (Int(c) << 8 | Int(input[i])) & 0x3FFF
                i += 1
                let distance = pair >> 3, length = (pair & 7) + 3
                guard distance > 0, distance <= out.count else { continue }
                for _ in 0..<length { out.append(out[out.count - distance]) }
            case 0xC0...0xFF:
                out.append(0x20)
                out.append(c ^ 0x80)
            default:
                out.append(c)
            }
        }
        return out
    }

    // MARK: INDX

    struct IndexEntry { var name: String, tags: [Int: [Int]] }

    private func readIndex(_ index: Int, kf8: (Int) -> Data?, header: Header) throws -> (table: [IndexEntry], cncx: [Int: String]) {
        guard index != nullIndex, let first = kf8(index) else { return ([], [:]) }
        let b = [UInt8](first)
        guard b.count > 184, b[0..<4].elementsEqual("INDX".utf8) else { throw AZW3Source.Failure.damaged("index") }
        let count = Int(b.be32(24)), cncxCount = Int(b.be32(52))
        var tagxStart = Int(b.be32(180))
        if !(tagxStart + 12 <= b.count && b[tagxStart..<tagxStart + 4].elementsEqual("TAGX".utf8)) {
            guard let found = b.firstRange(of: Array("TAGX".utf8)) else { throw AZW3Source.Failure.damaged("TAGX") }
            tagxStart = found.lowerBound
        }
        let firstEntry = Int(b.be32(tagxStart + 4)), controlBytes = Int(b.be32(tagxStart + 8))
        struct TagX { var tag, values, mask, eof: Int }
        var tagx: [TagX] = []
        var p = tagxStart + 12
        while p + 4 <= tagxStart + firstEntry, p + 4 <= b.count {
            tagx.append(TagX(tag: Int(b[p]), values: Int(b[p + 1]), mask: Int(b[p + 2]), eof: Int(b[p + 3])))
            p += 4
        }

        var cncx: [Int: String] = [:]
        for r in 0..<cncxCount {
            guard let rec = kf8(index + count + 1 + r) else { break }
            let bytes = [UInt8](rec)
            var pos = 0
            while pos < bytes.count {
                let (length, used) = Self.decint(bytes, at: pos)
                guard used > 0 else { break }
                if length > 0, pos + used + length <= bytes.count {
                    let raw = Data(bytes[pos + used..<pos + used + length])
                    cncx[pos + r * 0x10000] = header.isUTF8 ? String(decoding: raw, as: UTF8.self)
                        : (String(data: raw, encoding: .windowsCP1252) ?? "")
                }
                pos += used + max(length, 0)
            }
        }

        var table: [IndexEntry] = []
        for r in 0..<count {
            guard let rec = kf8(index + 1 + r) else { break }
            let d = [UInt8](rec)
            guard d.count > 28, d[0..<4].elementsEqual("INDX".utf8) else { continue }
            let idxt = Int(d.be32(20)), n = Int(d.be32(24))
            var positions: [Int] = (0..<n).compactMap { j in
                let at = idxt + 4 + 2 * j
                return at + 2 <= d.count ? Int(d.be16(at)) : nil
            }
            positions.append(idxt)
            for j in 0..<min(n, positions.count - 1) {
                let start = positions[j], end = min(positions[j + 1], d.count)
                guard start < end else { continue }
                let entry = Array(d[start..<end])
                let nameLength = Int(entry[0])
                guard 1 + nameLength <= entry.count else { continue }
                let nameBytes = Data(entry[1..<1 + nameLength])
                let name = header.isUTF8 ? String(decoding: nameBytes, as: UTF8.self) : (String(data: nameBytes, encoding: .windowsCP1252) ?? "")
                let rest = Array(entry[(1 + nameLength)...])
                table.append(IndexEntry(name: name, tags: Self.tagMap(rest, controlBytes: controlBytes, tagx: tagx.map { ($0.tag, $0.values, $0.mask, $0.eof) })))
            }
        }
        return (table, cncx)
    }

    static func tagMap(_ data: [UInt8], controlBytes: Int, tagx: [(tag: Int, values: Int, mask: Int, eof: Int)]) -> [Int: [Int]] {
        guard data.count >= controlBytes else { return [:] }
        var control = Array(data[0..<controlBytes])
        var pos = controlBytes
        var pending: [(tag: Int, count: Int?, bytes: Int?, values: Int)] = []
        for x in tagx {
            if x.eof == 1 {
                if !control.isEmpty { control.removeFirst() }
                continue
            }
            guard let cb = control.first else { break }
            var value = Int(cb) & x.mask
            guard value != 0 else { continue }
            if value == x.mask {
                if x.mask.nonzeroBitCount > 1 {
                    let (v, used) = decint(data, at: pos)
                    pos += used
                    pending.append((x.tag, nil, v, x.values))
                } else {
                    pending.append((x.tag, 1, nil, x.values))
                }
            } else {
                var mask = x.mask
                while mask & 1 == 0 { mask >>= 1; value >>= 1 }
                pending.append((x.tag, value, nil, x.values))
            }
        }
        var result: [Int: [Int]] = [:]
        for p in pending {
            var values: [Int] = []
            if let count = p.count {
                for _ in 0..<(count * p.values) {
                    let (v, used) = decint(data, at: pos)
                    pos += used
                    values.append(v)
                }
            } else if let total = p.bytes {
                var consumed = 0
                while consumed < total, pos < data.count {
                    let (v, used) = decint(data, at: pos)
                    pos += used
                    consumed += used
                    values.append(v)
                }
            }
            result[p.tag] = values
        }
        return result
    }

    /// Forward variable-width integer (high bit marks the last byte).
    static func decint(_ data: [UInt8], at start: Int) -> (Int, Int) {
        var value = 0, i = start
        while i < data.count {
            let b = data[i]
            value = value << 7 | Int(b & 0x7F)
            i += 1
            if b & 0x80 != 0 { break }
        }
        return (value, i - start)
    }

    // MARK: Markup helpers

    static func isBetweenTags(_ html: Data, _ pos: Int) -> Bool {
        let head = html.prefix(pos), tail = html.suffix(from: html.startIndex + pos)
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")
        let tailGT = tail.firstIndex(of: gt).map { $0 - tail.startIndex } ?? -1
        let tailLT = tail.firstIndex(of: lt).map { $0 - tail.startIndex } ?? -1
        let headGT = head.lastIndex(of: gt) ?? -1, headLT = head.lastIndex(of: lt) ?? -1
        return !(tailGT < tailLT || headGT < headLT)
    }

    static func endOfTag(withAID aid: String, in html: Data) -> Int? {
        let text = String(decoding: html, as: UTF8.self)
        let escaped = NSRegularExpression.escapedPattern(for: aid)
        guard let r = text.range(of: #"<[^>]*\said\s*=\s*['"]\#(escaped)['"][^>]*>"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return text.utf8.distance(from: text.startIndex, to: r.upperBound) - 1
    }

    static func tagsReversed(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<[^<>]*>") else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed().map { ns.substring(with: $0.range) }
    }

    static func attribute(_ names: [String], in tag: String) -> String? {
        guard tag.hasPrefix("<"), !tag.hasPrefix("</") else { return nil }
        for name in names {
            let pattern = name.lowercased() == "name" ? #"^<\s*a\s[^>]*\s?\#(name)\s*=\s*['"]([^'"]+)['"]"#
                : #"^<[^>]+\s\#(name)\s*=\s*['"]([^'"]+)['"]"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let m = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) {
                return (tag as NSString).substring(with: m.range(at: 1))
            }
        }
        return nil
    }

    static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            out += transform(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func imageType(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: Array("GIF8".utf8)) { return "gif" }
        if b.starts(with: Array("BM".utf8)) { return "bmp" }
        if b.count >= 12, b[0..<4].elementsEqual("RIFF".utf8), b[8..<12].elementsEqual("WEBP".utf8) { return "webp" }
        return nil
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    static func firstHeading(in file: URL) -> String? {
        guard let html = try? String(contentsOf: file, encoding: .utf8),
              let r = html.range(of: #"<h[1-3][^>]*>[\s\S]*?</h[1-3]>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let text = String(html[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : unescape(text)
    }
}

private extension Array where Element == UInt8 {
    func be16(_ at: Int) -> UInt16 { at + 2 <= count ? UInt16(self[at]) << 8 | UInt16(self[at + 1]) : 0 }
    func be32(_ at: Int) -> UInt32 {
        guard at + 4 <= count else { return 0 }
        return UInt32(self[at]) << 24 | UInt32(self[at + 1]) << 16 | UInt32(self[at + 2]) << 8 | UInt32(self[at + 3])
    }
}
