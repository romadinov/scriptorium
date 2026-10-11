import Foundation

/// Gives page text for any document: embedded text first, then cached OCR, then (on demand) fresh OCR.
public actor TextProvider {
    public let source: PageSource
    private let cacheDirectory: URL
    private var memory: [Int: PageText] = [:]
    public var ocr: OCRService

    public init(source: PageSource, ocr: OCRService = OCRService(), cacheRoot: URL? = nil) {
        self.source = source
        self.ocr = ocr
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appending(path: "OCR").appending(path: Self.cacheKey(for: source.url))
    }

    public func setLanguages(_ languages: [String]) {
        ocr.languages = languages
    }

    /// Text that is available without running OCR.
    public func availableText(page: Int) -> PageText? {
        if let cached = memory[page] { return cached }
        if let embedded = source.embeddedText(at: page) {
            memory[page] = embedded
            return embedded
        }
        if let data = try? Data(contentsOf: cacheFile(page)),
           let text = try? JSONDecoder().decode(PageText.self, from: data) {
            memory[page] = text
            return text
        }
        return nil
    }

    /// Returns text for the page, running OCR if the page has no text yet.
    public func text(page: Int, allowOCR: Bool = true) async throws -> PageText? {
        if let text = availableText(page: page) { return text }
        guard allowOCR else { return nil }
        return try await recognize(page: page)
    }

    /// Forces OCR (e.g. when the embedded layer is garbage) and caches the result.
    @discardableResult
    public func recognize(page: Int) async throws -> PageText {
        let image = try source.renderPage(at: page, maxPixelSize: 2600)
        let text = try await ocr.recognize(image)
        memory[page] = text
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(text).write(to: cacheFile(page))
        return text
    }

    /// Text of `page` plus neighbours, trimmed to `characterBudget` with the requested page kept in the middle.
    public func context(around page: Int, radius: Int, characterBudget: Int, allowOCR: Bool) async -> String {
        var parts: [String] = []
        let range = max(0, page - radius)...min(source.pageCount - 1, page + radius)
        for index in range {
            guard let raw = (try? await text(page: index, allowOCR: allowOCR && index == page))??.plainText else { continue }
            let text = RunningHeaders.stripped(raw, neighbours: await neighbourTexts(of: index))
            if !text.isEmpty { parts.append("[Page \(index + 1)]\n\(text)") }
        }
        let joined = parts.joined(separator: "\n\n")
        guard joined.count > characterBudget else { return joined }
        // Centre the window on the current page's marker.
        let marker = "[Page \(page + 1)]"
        let anchor = joined.range(of: marker).map { joined.distance(from: joined.startIndex, to: $0.lowerBound) } ?? 0
        let start = max(0, min(anchor - characterBudget / 4, joined.count - characterBudget))
        let from = joined.index(joined.startIndex, offsetBy: start)
        let to = joined.index(from, offsetBy: characterBudget)
        return "…" + joined[from..<to] + "…"
    }

    /// Text of the pages around `page` (±2, no OCR) — what running headers are recognised against.
    public func neighbourTexts(of page: Int) async -> [String] {
        var result: [String] = []
        for index in [page - 2, page - 1, page + 1, page + 2] where index >= 0 && index < source.pageCount {
            if let t = (try? await text(page: index, allowOCR: false))??.plainText, !t.isEmpty { result.append(t) }
        }
        return result
    }

    private func cacheFile(_ page: Int) -> URL {
        cacheDirectory.appending(path: "\(page).json")
    }

    private static func cacheKey(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .prefix(60)
        return "\(name)-\(size)"
    }
}
