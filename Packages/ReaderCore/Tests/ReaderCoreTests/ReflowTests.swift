import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import ReaderCore

@Suite struct ReflowTests {
    typealias Rules = PageLayoutRules

    @Test func recognisesFormulas() {
        #expect(Rules.isFormula("∫ f(x) dx = F(b) − F(a)"))
        #expect(Rules.isFormula("S = k log W"))
        #expect(Rules.isFormula("E = mc^2 + Σ λ_i"))
        #expect(!Rules.isFormula("Ludwig Boltzmann expressed this idea in the formula below, where W is"))
        #expect(!Rules.isFormula("The second law of thermodynamics states that the total entropy"))
    }

    @Test func joinsLinesAndUndoesHyphenation() {
        #expect(Rules.join(["The con-", "cept of en-", "tropy is", "well-", "Known"]) == "The concept of entropy is well- Known")
    }

    @Test func layoutSplitsAroundFormulasAndPlacesFigures() {
        func line(_ t: String, y: CGFloat, h: CGFloat = 0.02) -> Rules.Line { .init(text: t, rect: CGRect(x: 0.1, y: y, width: 0.8, height: h)) }
        let page = [
            Rules.Paragraph(lines: [line("Chapter One", y: 0.08, h: 0.04)], rect: CGRect(x: 0.1, y: 0.08, width: 0.8, height: 0.04)),
            Rules.Paragraph(lines: [line("Boltzmann wrote it as", y: 0.15), line("S = k log W", y: 0.18), line("which we use below.", y: 0.21)],
                            rect: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.08)),
            Rules.Paragraph(lines: [line("Text after the picture.", y: 0.7)], rect: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.02)),
            Rules.Paragraph(lines: [line("Axis label", y: 0.4)], rect: CGRect(x: 0.3, y: 0.4, width: 0.2, height: 0.02)),
            Rules.Paragraph(lines: [line("17", y: 0.96)], rect: CGRect(x: 0.5, y: 0.96, width: 0.03, height: 0.02)),
        ]
        let figure = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.3)
        let layout = Rules.layout(paragraphs: page, figures: [figure])
        #expect(layout.blocks == [
            .heading("Chapter One"),
            .paragraph("Boltzmann wrote it as"),
            .formula(CGRect(x: 0.1, y: 0.18, width: 0.8, height: 0.02)),
            .paragraph("which we use below."),
            .figure(figure),                         // its label is part of the picture
            .paragraph("Text after the picture."),   // the page number is gone
        ])
        let html = Rules.xhtml(layout, title: "Page 1") { "img\($0).png" }
        #expect(html.contains("<h2>Chapter One</h2>") && html.contains("img2.png") && html.contains("em\"/>"))
    }

    @Test func findsInkRegions() {
        var ink = Array(repeating: Array(repeating: false, count: 50), count: 50)
        for r in 10..<30 { for c in 10..<40 where (r + c) % 3 != 0 { ink[r][c] = true } }   // a dotted drawing
        ink[45][5] = true                                                                // a speck
        let boxes = Rules.figureBoxes(ink: ink)
        #expect(boxes.count == 1)
        #expect(abs(boxes[0].minX - 0.2) < 0.03 && abs(boxes[0].height - 0.4) < 0.03)
    }

    /// End to end on a generated page: prose, a display formula, a drawing.
    @Test func convertsAGeneratedPDFPage() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "reflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdfURL = dir.appending(path: "Page.pdf")
        try makePDF(at: pdfURL)
        let source = try PDFPageSource(url: pdfURL)
        let out = dir.appending(path: "out")
        try await PageReflower.convert(source, page: 0, into: out, languages: ["en-US"])
        let html = try String(contentsOf: out.appending(path: "page-00001.xhtml"), encoding: .utf8)
        #expect(html.contains("entropy of an isolated system"))
        #expect(html.contains("alt=\"illustration\""), "drawing not kept: \(html)")
        let images = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".png") }
        #expect(!images.isEmpty)
    }

    private func makePDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        func text(_ s: String, y: CGFloat, size: CGFloat = 13) {
            let font = CTFontCreateWithName("Times New Roman" as CFString, size, nil)
            let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRange(),
                                                 CGPath(rect: CGRect(x: 72, y: y, width: 468, height: 120), transform: nil), nil)
            CTFrameDraw(frame, ctx)
        }
        text("The second law of thermodynamics states that the total entropy of an isolated system can never decrease over time. Entropy is often described as a measure of disorder, but a more precise statement is that it counts microscopic configurations.", y: 600)
        text("∫ dQ / T  =  ΔS  ≥  0", y: 540, size: 16)
        // A drawing: circle and axes.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: 200, y: 200, width: 200, height: 200))
        ctx.move(to: CGPoint(x: 180, y: 300)); ctx.addLine(to: CGPoint(x: 420, y: 300)); ctx.strokePath()
        text("Boltzmann expressed this idea in a formula relating entropy to the number of microstates of the gas in the container.", y: 60)
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
