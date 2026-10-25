import CoreGraphics
import Foundation

/// A page turned into reflowable pieces: text paragraphs, and regions kept as images (illustrations and
/// display formulas, cropped from the page). Rects are normalised to 0...1, origin top-left.
public struct PageLayout: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(String)
        /// Cropped from the page: a display formula (sized with the text) or an illustration (sized with the page).
        case formula(CGRect)
        case figure(CGRect)
    }

    public var blocks: [Block]
    /// Median text line height on the page (normalised): formula images are sized relative to it.
    public var lineHeight: CGFloat

    public init(blocks: [Block], lineHeight: CGFloat) {
        self.blocks = blocks
        self.lineHeight = lineHeight
    }
}

/// The pure layout rules (Vision and pixels stay in `PageReflower`), so they can be tested.
public enum PageLayoutRules {
    /// A recognised line of text: its string and where it is.
    public struct Line: Equatable, Sendable {
        public var text: String
        public var rect: CGRect
        public init(text: String, rect: CGRect) {
            self.text = text
            self.rect = rect
        }
    }

    /// A paragraph as Vision found it: its lines in order.
    public struct Paragraph: Equatable, Sendable {
        public var lines: [Line]
        public var rect: CGRect
        public init(lines: [Line], rect: CGRect) {
            self.lines = lines
            self.rect = rect
        }
    }

    private static let mathSymbols = Set("=+−±×÷·∙/^_∑∏∫∮√∂∇∆≤≥≠≈≡∝∞→←↔⇒⇔∈∉⊂⊃∪∩∀∃αβγδεζηθλμνξπρστφχψωΓΔΘΛΞΠΣΦΨΩ")
    private static let strongMath = Set("∑∏∫∮√∂∇≤≥≠≈≡∝∞⇒⇔∈∉⊂⊃∪∩∀∃")

    /// A line that is a display formula rather than prose: math symbols, few real words.
    /// (OCR turns formulas into symbol soup, so cropping them keeps them exact.)
    public static func isFormula(_ text: String) -> Bool {
        let chars = text.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return false }
        // Section numbers ("1.1.1") and plain numbers are text, not formulas.
        if text.range(of: #"^\s*[\d.]+\s*$"#, options: .regularExpression) != nil { return false }
        let math = chars.filter { mathSymbols.contains($0) }.count
        let words = text.split { !$0.isLetter }.filter { $0.count >= 4 }.count
        if chars.contains(where: { strongMath.contains($0) }) && words <= 3 { return true }
        // Mostly digits, brackets and symbols with at most one real word: "Q = {q0, q1, q2, qY, qN}".
        let nonLetters = chars.filter { !$0.isLetter }.count
        if words <= 1 && chars.count <= 80 && Double(nonLetters) / Double(chars.count) >= 0.45 && chars.count >= 3 { return true }
        // A short line built around a relation with no real words: "S = k log W".
        if chars.contains(where: { "=<>≤≥≈".contains($0) }) && words == 0 && chars.count <= 60 { return true }
        return Double(math) / Double(chars.count) >= 0.18 && words <= 2 && chars.count <= 120
    }

    /// Joins a paragraph's lines, undoing end-of-line hyphenation ("con-" + "cept" → "concept").
    public static func join(_ lines: [String]) -> String {
        var text = ""
        for line in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if text.hasSuffix("-"), let first = line.first, first.isLowercase,
               let beforeHyphen = text.dropLast().last, beforeHyphen.isLetter {
                text.removeLast()
                text += line
            } else {
                text += text.isEmpty ? line : " " + line
            }
        }
        return text
    }

    /// Lays out a page: paragraphs (split around display formulas), headings by size, running heads and
    /// page numbers dropped, illustrations placed where they sit. `figures` come from ink analysis.
    public static func layout(paragraphs: [Paragraph], figures inkFigures: [CGRect]) -> PageLayout {
        let heights = paragraphs.flatMap(\.lines).map(\.rect.height).sorted()
        let lineHeight = heights.isEmpty ? 0.02 : heights[heights.count / 2]
        let allLines = paragraphs.flatMap(\.lines)
        let figures = grow(inkFigures + diagramRows(allLines, lineHeight: lineHeight), with: allLines, lineHeight: lineHeight)

        // Text inside an illustration (labels, axes) belongs to the picture.
        func insideFigure(_ r: CGRect) -> Bool {
            figures.contains { f in
                let i = f.intersection(r)
                return !i.isNull && i.width * i.height >= 0.6 * r.width * r.height
            }
        }
        // Running heads and page numbers: short lines at the very top or bottom.
        func isMargin(_ p: Paragraph) -> Bool {
            let text = p.lines.map(\.text).joined(separator: " ")
            return (p.rect.minY < 0.06 || p.rect.maxY > 0.94) && text.count < 60
        }

        // The text column's width: body lines span it, headings don't.
        let widths = allLines.map(\.rect.width).sorted()
        let column = widths.isEmpty ? 1 : widths[widths.count * 3 / 4]
        func isHeading(_ line: Line, in p: Paragraph) -> Bool {
            guard let i = p.lines.firstIndex(of: line), i + 1 < p.lines.count else { return false }
            let previousEndsSentence = i == 0 || ".!?:".contains(p.lines[i - 1].text.last ?? ".")
            let text = line.text.trimmingCharacters(in: .whitespaces)
            return previousEndsSentence && text.count <= 70 && line.rect.width < column * 0.65
                && !".,;:!?".contains(text.last ?? ".") && p.lines[i + 1].text.first?.isUppercase == true
                && text.first.map { $0.isUppercase || $0.isNumber } == true
        }

        var placed: [(y: CGFloat, block: PageLayout.Block)] = []
        for p in paragraphs where !insideFigure(p.rect) && !isMargin(p) {
            var pending: [Line] = []
            var pendingNumber: Line?   // a bare section number ("1.1") waiting for its title
            func flush() {
                guard !pending.isEmpty else { return }
                let text = join(pending.map(\.text))
                let avg = pending.map(\.rect.height).reduce(0, +) / CGFloat(pending.count)
                let letters = text.filter(\.isLetter)
                let allCaps = letters.count >= 4 && letters.allSatisfy { !$0.isLowercase }
                let heading = (avg > lineHeight * 1.35 || allCaps) && text.count < 140 && !text.hasSuffix(".")
                placed.append((pending[0].rect.minY, heading ? .heading(text) : .paragraph(text)))
                pending = []
            }
            for line in p.lines where !insideFigure(line.rect) {
                let bareNumber = line.text.range(of: #"^\s*\d+(\.\d+)*\.?\s*$"#, options: .regularExpression) != nil
                if bareNumber && line.text.count <= 8 {
                    flush()
                    pendingNumber = line
                } else if let number = pendingNumber {
                    // "1.1" + "Offensive Security" on the same row: one heading.
                    pendingNumber = nil
                    placed.append((number.rect.minY, .heading(number.text.trimmingCharacters(in: .whitespaces) + " " + line.text)))
                } else if isFormula(line.text) {
                    flush()
                    placed.append((line.rect.minY, .formula(line.rect)))
                } else if isHeading(line, in: p) {
                    // A short line between sentence ends, followed by a new sentence: a heading Vision grouped
                    // with the text around it.
                    flush()
                    placed.append((line.rect.minY, .heading(line.text)))
                } else {
                    pending.append(line)
                }
            }
            if let number = pendingNumber { pending.append(number) }
            flush()
        }
        // Vision sometimes ends a paragraph at a line break mid-sentence: rejoin text that doesn't end one.
        var joined: [(y: CGFloat, block: PageLayout.Block)] = []
        for item in placed {
            if case .paragraph(let next) = item.block, case .paragraph(let previous)? = joined.last?.block,
               let end = previous.last, !".!?:;…»\"”)".contains(end) {
                // A short title-like line before a new sentence is a heading, not half a sentence.
                let titleLike = previous.count <= 70 && next.first?.isUppercase == true
                    && previous.first.map { $0.isUppercase || $0.isNumber } == true && !",".contains(end)
                if titleLike {
                    joined[joined.count - 1].block = .heading(previous)
                    joined.append(item)
                } else {
                    joined[joined.count - 1].block = .paragraph(join([previous, next]))
                }
            } else {
                joined.append(item)
            }
        }
        placed = joined
        // Illustrations go before the first text that starts below them (Vision's order is reading order,
        // so text keeps its order; pictures slot in by position).
        var blocks = placed.map(\.block)
        for figure in figures.sorted(by: { $0.minY > $1.minY }) {
            let index = placed.firstIndex { $0.y > figure.minY } ?? placed.count
            blocks.insert(.figure(figure), at: min(index, blocks.count))
        }
        // Consecutive formula lines (a multi-line equation) become one image.
        var merged: [PageLayout.Block] = []
        for block in blocks {
            if case .formula(let r) = block, case .formula(let previous)? = merged.last,
               r.minY - previous.maxY < lineHeight * 1.2 {
                merged[merged.count - 1] = .formula(previous.union(r))
            } else {
                merged.append(block)
            }
        }
        return PageLayout(blocks: merged, lineHeight: lineHeight)
    }

    static func medianHeight(_ lines: [Line]) -> CGFloat {
        let heights = lines.map(\.rect.height).sorted()
        return heights.isEmpty ? 0.02 : heights[heights.count / 2]
    }

    /// A digital PDF's own lines, grouped into paragraphs the way Vision grouped what it saw: each line goes
    /// to the Vision paragraph containing it; lines no paragraph contains stand alone, in page order.
    public static func regroup(_ lines: [Line], by vision: [Paragraph]) -> [Paragraph] {
        var buckets = Array(repeating: [Line](), count: vision.count)
        var loose: [Line] = []
        for line in lines {
            let center = CGPoint(x: line.rect.midX, y: line.rect.midY)
            if let i = vision.firstIndex(where: { $0.rect.insetBy(dx: -0.01, dy: -0.004).contains(center) }) {
                buckets[i].append(line)
            } else {
                loose.append(line)
            }
        }
        var result: [Paragraph] = []
        for (i, bucket) in buckets.enumerated() where !bucket.isEmpty {
            let sorted = bucket.sorted { abs($0.rect.minY - $1.rect.minY) < 0.004 ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
            result.append(Paragraph(lines: sorted, rect: vision[i].rect))
        }
        for line in loose {
            let index = result.firstIndex { $0.rect.minY > line.rect.minY } ?? result.count
            result.insert(Paragraph(lines: [line], rect: line.rect), at: index)
        }
        return result
    }

    /// Box-and-arrow diagrams and tables: rows holding three or more short labels side by side. Each such
    /// row (merged with adjacent ones) becomes a picture, so the labels aren't read out as a sentence.
    static func diagramRows(_ lines: [Line], lineHeight: CGFloat) -> [CGRect] {
        let short = lines.filter { $0.text.count <= 32 }
        var rows: [[Line]] = []
        for line in short.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let i = rows.firstIndex(where: { row in row.contains { abs($0.rect.midY - line.rect.midY) < lineHeight * 0.6 } }) {
                rows[i].append(line)
            } else {
                rows.append([line])
            }
        }
        var boxes: [CGRect] = []
        for row in rows where row.count >= 3 {
            let sorted = row.sorted { $0.rect.minX < $1.rect.minX }
            // Separate cells, not one sentence broken into words: clear gaps between them.
            let gaps = zip(sorted, sorted.dropFirst()).map { $1.rect.minX - $0.rect.maxX }
            guard gaps.filter({ $0 > 0.02 }).count >= 2 else { continue }
            let box = row.map(\.rect).reduce(row[0].rect) { $0.union($1) }
            if let i = boxes.firstIndex(where: { max($0.minY, box.minY) - min($0.maxY, box.maxY) < lineHeight * 1.5 }) {
                boxes[i] = boxes[i].union(box)
            } else {
                boxes.append(box)
            }
        }
        // A little room for the boxes' borders and arrows around the labels.
        return boxes.map { $0.insetBy(dx: -0.02, dy: -lineHeight * 0.8) }
    }

    /// Diagrams come with labels and symbol-only lines (tape cells, axis marks) that OCR turns into noise:
    /// lines like that next to a picture join it, and pictures with only small gaps between them merge.
    static func grow(_ figures: [CGRect], with lines: [Line], lineHeight: CGFloat) -> [CGRect] {
        guard !figures.isEmpty else { return [] }
        func isLabel(_ line: Line) -> Bool {
            let words = line.text.split { !$0.isLetter }.filter { $0.count >= 3 }.count
            return words <= 1 || isFormula(line.text)
        }
        func near(_ a: CGRect, _ b: CGRect, _ gap: CGFloat) -> Bool {
            let overlapsX = a.minX < b.maxX && b.minX < a.maxX
            return overlapsX && (a.intersects(b) || max(a.minY, b.minY) - min(a.maxY, b.maxY) < gap)
        }
        var result = figures
        var changed = true
        while changed {
            changed = false
            for line in lines where isLabel(line) {
                // Above/below the picture, or beside it on the same rows (row labels like "q0:").
                func beside(_ f: CGRect) -> Bool {
                    f.minY < line.rect.maxY && line.rect.minY < f.maxY && max(f.minX, line.rect.minX) - min(f.maxX, line.rect.maxX) < 0.12
                }
                if let i = result.firstIndex(where: { (near($0, line.rect, lineHeight * 3) || beside($0)) && !$0.contains(line.rect) }) {
                    result[i] = result[i].union(line.rect)
                    changed = true
                }
            }
            outer: for i in result.indices {
                for j in result.indices where j > i && near(result[i], result[j], lineHeight * 3) {
                    result[i] = result[i].union(result[j])
                    result.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return result
    }

    /// Illustrations from an ink map: `ink[row][col]` true where the page has marks, text lines already
    /// removed. Connected regions (bridging small gaps) larger than `minArea` of the page become boxes.
    public static func figureBoxes(ink: [[Bool]], minArea: CGFloat = 0.01, gap: Int = 2) -> [CGRect] {
        let rows = ink.count, cols = ink.first?.count ?? 0
        guard rows > 0, cols > 0 else { return [] }
        var seen = Array(repeating: Array(repeating: false, count: cols), count: rows)
        var boxes: [CGRect] = []
        for r in 0..<rows {
            for c in 0..<cols where ink[r][c] && !seen[r][c] {
                var stack = [(r, c)]
                seen[r][c] = true
                var (minR, maxR, minC, maxC) = (r, r, c, c)
                while let (y, x) = stack.popLast() {
                    minR = min(minR, y); maxR = max(maxR, y); minC = min(minC, x); maxC = max(maxC, x)
                    for dy in -gap...gap {
                        for dx in -gap...gap {
                            let (ny, nx) = (y + dy, x + dx)
                            guard ny >= 0, ny < rows, nx >= 0, nx < cols, ink[ny][nx], !seen[ny][nx] else { continue }
                            seen[ny][nx] = true
                            stack.append((ny, nx))
                        }
                    }
                }
                let box = CGRect(x: CGFloat(minC) / CGFloat(cols), y: CGFloat(minR) / CGFloat(rows),
                                 width: CGFloat(maxC - minC + 1) / CGFloat(cols), height: CGFloat(maxR - minR + 1) / CGFloat(rows))
                if box.width * box.height >= minArea, box.height >= 0.03 { boxes.append(box) }
            }
        }
        return boxes
    }

    /// The page as XHTML. `image(i)` names the cropped image for block i.
    public static func xhtml(_ layout: PageLayout, title: String, image: (Int) -> String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var body = ""
        for (i, block) in layout.blocks.enumerated() {
            switch block {
            case .paragraph(let text): body += "<p>\(escape(text))</p>\n"
            case .heading(let text): body += "<h2>\(escape(text))</h2>\n"
            case .formula(let r):
                // Height in em, so the formula grows and shrinks with the text size.
                let em = max(1.0, Double((r.height + layout.lineHeight * 1.2) / max(layout.lineHeight, 0.001)) * 0.9)
                body += "<div class=\"formula\"><img src=\"\(image(i))\" alt=\"formula\" style=\"height: \(String(format: "%.2f", em))em\"/></div>\n"
            case .figure(let r):
                let width = min(100, Int((r.width * 100 * 1.1).rounded()))
                body += "<figure><img src=\"\(image(i))\" alt=\"illustration\" style=\"width: \(width)%\"/></figure>\n"
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="UTF-8"/><title>\(escape(title))</title>
        <style>
        .formula { text-align: center; margin: 0.6em 0; }
        .formula img { max-width: 100%; object-fit: contain; vertical-align: middle; }
        figure { margin: 1em 0; text-align: center; }
        figure img { max-width: 100%; height: auto; }
        @media (prefers-color-scheme: dark) { .formula img, figure img { filter: invert(1) hue-rotate(180deg); } }
        </style></head>
        <body>
        \(body)</body></html>
        """
    }
}
