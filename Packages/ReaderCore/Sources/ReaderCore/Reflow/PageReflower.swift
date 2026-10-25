import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Converts one PDF/DjVu page into reflowable XHTML: Vision reads the paragraphs; illustrations, tables
/// and display formulas are cropped from the page image so they stay exactly as printed.
public enum PageReflower {
    static let renderSize = 2200

    public static func convert(_ source: PageSource, page index: Int, into directory: URL, languages: [String]) async throws {
        let image = try source.renderPage(at: index, maxPixelSize: renderSize)
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = languages.isEmpty
        if !languages.isEmpty { request.textRecognitionOptions.recognitionLanguages = languages.map { Locale.Language(identifier: $0) } }
        request.textRecognitionOptions.useLanguageCorrection = true
        let documents = try await request.perform(on: image)

        // A digital PDF's own lines (exact text, exact position) beat OCR: Vision only says which lines form a
        // paragraph. Scans and DjVus (often garbled text layers) use Vision's reading.
        var pdfLines = (source as? PDFPageSource)?.textLines(at: index) ?? []
        // An embedded picture shows up in the text as U+FFFC, with the picture's bounds.
        let pdfImages = pdfLines.filter { $0.text.unicodeScalars.allSatisfy { $0 == "\u{FFFC}" || $0 == " " } }.map(\.rect)
        pdfLines.removeAll { $0.text.unicodeScalars.allSatisfy { $0 == "\u{FFFC}" || $0 == " " } }
        var paragraphs: [PageLayoutRules.Paragraph] = []
        var tables: [CGRect] = []
        for document in documents {
            let container = document.document
            for paragraph in container.paragraphs {
                let lines = paragraph.lines.map { line in
                    PageLayoutRules.Line(text: line.topCandidates(1).first?.string ?? "", rect: topLeft(line.boundingBox.cgRect))
                }.filter { !$0.text.isEmpty }
                if !lines.isEmpty { paragraphs.append(.init(lines: lines, rect: topLeft(paragraph.boundingRegion.boundingBox.cgRect))) }
            }
            // Tables keep their grid: crop them like pictures.
            tables += container.tables.map { topLeft($0.boundingRegion.boundingBox.cgRect) }
        }
        // Diagram labels drawn inside pictures are only in what Vision read, not in the PDF's text.
        let visionLines = paragraphs.flatMap(\.lines)
        let labelRows = PageLayoutRules.diagramRows(visionLines, lineHeight: PageLayoutRules.medianHeight(visionLines))
        if !pdfLines.isEmpty { paragraphs = PageLayoutRules.regroup(pdfLines.map { .init(text: $0.text, rect: $0.rect) }, by: paragraphs) }
        let textRects = paragraphs.flatMap(\.lines).map(\.rect)
        let figures = figureRegions(in: image, excluding: textRects) + tables + labelRows
            + pdfImages.map { $0.insetBy(dx: -0.005, dy: -0.01) }
        let layout = PageLayoutRules.layout(paragraphs: paragraphs.filter { p in
            !tables.contains { $0.intersects(p.rect) }
        }, figures: figures)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = ReflowedSource.stem(index)
        for (i, block) in layout.blocks.enumerated() {
            switch block {
            case .formula(let r):
                // Room above and below for limits, superscripts and subscripts that sit outside the text line.
                try writePNG(crop(image, r.insetBy(dx: 0, dy: -layout.lineHeight * 0.6)), to: directory.appending(path: "\(stem)-\(i).png"))
            case .figure(let r):
                try writePNG(crop(image, r), to: directory.appending(path: "\(stem)-\(i).png"))
            default: break
            }
        }
        let html = PageLayoutRules.xhtml(layout, title: "Page \(index + 1)") { "\(stem)-\($0).png" }
        try Data(html.utf8).write(to: directory.appending(path: "\(stem).xhtml"), options: .atomic)
    }

    /// Vision's normalised rects have a lower-left origin; layout uses top-left.
    static func topLeft(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

    /// Marked areas of the page that aren't text: drawings, photos, diagrams.
    static func figureRegions(in image: CGImage, excluding text: [CGRect]) -> [CGRect] {
        let cols = 480, rows = max(1, Int(Double(cols) * Double(image.height) / Double(image.width)))
        var pixels = [UInt8](repeating: 255, count: cols * rows)
        guard let context = CGContext(data: &pixels, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        // Row 0 of the buffer is the top of the page.
        // Ink is anything clearly darker than the paper (scans aren't white; pale diagram fills count too).
        let paper = Int(pixels.sorted()[pixels.count * 3 / 4])
        let threshold = UInt8(max(0, min(paper - 18, 235)))
        var ink = (0..<rows).map { r in (0..<cols).map { c in pixels[r * cols + c] < threshold } }
        // Ignore scan borders and the text itself (slightly padded).
        let margin = 0.02
        for r in 0..<rows {
            for c in 0..<cols {
                let x = (Double(c) + 0.5) / Double(cols), y = (Double(r) + 0.5) / Double(rows)
                if x < margin || x > 1 - margin || y < margin || y > 1 - margin { ink[r][c] = false; continue }
                let point = CGPoint(x: x, y: y)
                if text.contains(where: { $0.insetBy(dx: -0.004, dy: -0.004).contains(point) }) { ink[r][c] = false }
            }
        }
        return PageLayoutRules.figureBoxes(ink: ink, gap: 4)
    }

    static func crop(_ image: CGImage, _ r: CGRect) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pad: CGFloat = 0.006
        let rect = CGRect(x: (r.minX - pad) * w, y: (r.minY - pad) * h, width: (r.width + 2 * pad) * w, height: (r.height + 2 * pad) * h)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return image.cropping(to: rect) ?? image
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
