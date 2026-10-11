import CDjVuLibre
import CoreGraphics
import Foundation

/// DjVu document backed by DjVuLibre's ddjvuapi.
///
/// DjVuLibre keeps process-wide state (the minilisp GC, message queues), so every call
/// into it — across all documents — is serialised through one global lock.
/// All decoding is done synchronously by pumping the message queue until the job finishes;
/// callers are expected to invoke this off the main thread.
public final class DjVuPageSource: PageSource, @unchecked Sendable {
    public let url: URL
    public private(set) var pageCount: Int = 0
    public private(set) lazy var outline: [OutlineItem] = locked { loadOutline() }

    private let context: OpaquePointer
    private let document: OpaquePointer
    private static let lock = NSRecursiveLock()
    private var pageInfo: [Int: ddjvu_pageinfo_t] = [:]

    private static let miniexpDummy = OpaquePointer(bitPattern: 2)

    public init(url: URL) throws {
        self.url = url
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let ctx = ddjvu_context_create("Reader") else { throw DocumentError.cannotOpen(url) }
        guard let doc = url.path.withCString({ ddjvu_document_create_by_filename_utf8(ctx, $0, 1) }) else {
            ddjvu_context_release(ctx)
            throw DocumentError.cannotOpen(url)
        }
        context = ctx
        document = doc
        while ddjvu_job_status(ddjvu_document_job(doc)).rawValue < DDJVU_JOB_OK.rawValue { pump(wait: true) }
        guard ddjvu_job_status(ddjvu_document_job(doc)) == DDJVU_JOB_OK else { throw DocumentError.cannotOpen(url) }
        pageCount = Int(ddjvu_document_get_pagenum(doc))
    }

    deinit {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        ddjvu_job_release(ddjvu_document_job(document))
        ddjvu_context_release(context)
    }

    // MARK: PageSource

    public func pageSize(at index: Int) -> CGSize {
        guard let info = info(for: index), info.dpi > 0 else { return CGSize(width: 612, height: 792) }
        let scale = 72.0 / Double(info.dpi)
        let rotated = info.rotation % 2 == 1
        let w = Double(info.width) * scale, h = Double(info.height) * scale
        return rotated ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    public func renderPage(at index: Int, maxPixelSize: Int) throws -> CGImage {
        try locked {
            guard let page = ddjvu_page_create_by_pageno(document, Int32(index)) else {
                throw DocumentError.renderFailed(page: index)
            }
            defer { ddjvu_job_release(ddjvu_page_job(page)) }
            while ddjvu_job_status(ddjvu_page_job(page)).rawValue < DDJVU_JOB_OK.rawValue { pump(wait: true) }
            guard ddjvu_job_status(ddjvu_page_job(page)) == DDJVU_JOB_OK else { throw DocumentError.renderFailed(page: index) }

            // Width/height already account for the page's initial rotation.
            let fullW = Int(ddjvu_page_get_width(page)), fullH = Int(ddjvu_page_get_height(page))
            guard fullW > 0, fullH > 0 else { throw DocumentError.renderFailed(page: index) }
            let scale = min(1.0, Double(maxPixelSize) / Double(max(fullW, fullH)))
            let w = max(1, Int(Double(fullW) * scale)), h = max(1, Int(Double(fullH) * scale))

            var rect = ddjvu_rect_t(x: 0, y: 0, w: UInt32(w), h: UInt32(h))
            var renderRect = rect
            guard let format = ddjvu_format_create(DDJVU_FORMAT_RGB24, 0, nil) else {
                throw DocumentError.renderFailed(page: index)
            }
            defer { ddjvu_format_release(format) }
            ddjvu_format_set_row_order(format, 1)
            ddjvu_format_set_y_direction(format, 1)

            let rowBytes = w * 3
            var pixels = [UInt8](repeating: 0xFF, count: rowBytes * h)
            let ok = pixels.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                    ddjvu_page_render(page, DDJVU_RENDER_COLOR, &rect, &renderRect, format, UInt(rowBytes), $0)
                }
            }
            // ok == 0 means nothing to draw (blank page); keep the white buffer.
            _ = ok

            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(
                      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: rowBytes,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw DocumentError.renderFailed(page: index) }
            return image
        }
    }

    public func embeddedText(at index: Int) -> PageText? {
        locked {
            var exp: OpaquePointer?
            repeat {
                exp = ddjvu_document_get_pagetext(document, Int32(index), "word")
                if exp == Self.miniexpDummy { pump(wait: true) }
            } while exp == Self.miniexpDummy
            guard let exp else { return nil }
            defer { ddjvu_miniexp_release(document, exp) }

            guard let info = info(for: index), info.width > 0, info.height > 0 else { return nil }
            var collector = TextCollector(width: Double(info.width), height: Double(info.height))
            collector.walk(exp)
            collector.flushLine()
            let text = PageText(origin: .embedded, lines: collector.lines)
            return text.isEmpty ? nil : text
        }
    }

    // MARK: Private

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try body()
    }

    private func info(for index: Int) -> ddjvu_pageinfo_t? {
        locked {
            if let cached = pageInfo[index] { return cached }
            var info = ddjvu_pageinfo_t()
            var status: ddjvu_status_t
            repeat {
                status = ddjvu_document_get_pageinfo_imp(document, Int32(index), &info, UInt32(MemoryLayout<ddjvu_pageinfo_t>.size))
                if status.rawValue < DDJVU_JOB_OK.rawValue { pump(wait: true) }
            } while status.rawValue < DDJVU_JOB_OK.rawValue
            guard status == DDJVU_JOB_OK else { return nil }
            pageInfo[index] = info
            return info
        }
    }

    /// Drains the ddjvu message queue. Errors are logged; everything else is just consumed —
    /// callers poll job status themselves.
    private func pump(wait: Bool) {
        if wait { ddjvu_message_wait(context) }
        while let msg = ddjvu_message_peek(context) {
            if msg.pointee.m_any.tag == DDJVU_ERROR, let text = msg.pointee.m_error.message {
                NSLog("DjVu: %@", String(cString: text))
            }
            ddjvu_message_pop(context)
        }
    }

    private func loadOutline() -> [OutlineItem] {
        var exp: OpaquePointer?
        repeat {
            exp = ddjvu_document_get_outline(document)
            if exp == Self.miniexpDummy { pump(wait: true) }
        } while exp == Self.miniexpDummy
        guard let exp else { return [] }
        defer { ddjvu_miniexp_release(document, exp) }
        // (bookmarks ("title" "#page" children...) ...)
        return Self.outlineItems(miniexp_cdr(exp))
    }

    private static func outlineItems(_ list: OpaquePointer?) -> [OutlineItem] {
        var items: [OutlineItem] = []
        var cursor = list
        while miniexp_consp(cursor) != 0 {
            let entry = miniexp_car(cursor)
            let title = miniexp_car(entry)
            let target = miniexp_cadr(entry)
            if miniexp_stringp(title) != 0 {
                let name = String(cString: miniexp_to_str(title))
                var page: Int?
                if miniexp_stringp(target) != 0 {
                    let link = String(cString: miniexp_to_str(target))
                    // Links look like "#12" (1-based page number); named-page links are ignored.
                    if link.hasPrefix("#"), let n = Int(link.dropFirst()) { page = n - 1 }
                }
                items.append(OutlineItem(title: name, pageIndex: page, children: outlineItems(miniexp_cddr(entry))))
            }
            cursor = miniexp_cdr(cursor)
        }
        return items
    }
}

/// Walks a DjVu hidden-text s-expression: `(page x0 y0 x1 y1 (line ... (word x0 y0 x1 y1 "text")))`.
/// DjVu coordinates have the origin at the bottom-left; output rects are normalised, top-left origin.
private struct TextCollector {
    let width: Double
    let height: Double
    var lines: [[PageText.Word]] = []
    private var current: [PageText.Word] = []

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    mutating func walk(_ exp: OpaquePointer?) {
        guard miniexp_consp(exp) != 0 else { return }
        let head = miniexp_car(exp)
        let kind = miniexp_symbolp(head) != 0 ? String(cString: miniexp_to_name(head)) : ""
        var coords: [Int] = []
        var rest = miniexp_cdr(exp)
        while coords.count < 4, miniexp_numberp(miniexp_car(rest)) != 0 {
            coords.append(Int(miniexp_to_int(miniexp_car(rest))))
            rest = miniexp_cdr(rest)
        }

        if kind == "line" { flushLine() }

        var child = rest
        while miniexp_consp(child) != 0 {
            let item = miniexp_car(child)
            if miniexp_stringp(item) != 0, coords.count == 4 {
                let text = String(cString: miniexp_to_str(item))
                if !text.isEmpty {
                    current.append(PageText.Word(text: text, rect: normalised(coords)))
                }
            } else {
                walk(item)
            }
            child = miniexp_cdr(child)
        }

        if kind == "line" || kind == "para" || kind == "region" { flushLine() }
    }

    mutating func flushLine() {
        if !current.isEmpty { lines.append(current) }
        current = []
    }

    private func normalised(_ c: [Int]) -> CGRect {
        let x0 = Double(c[0]), y0 = Double(c[1]), x1 = Double(c[2]), y1 = Double(c[3])
        return CGRect(x: x0 / width, y: 1 - y1 / height, width: (x1 - x0) / width, height: (y1 - y0) / height)
    }
}
