import Foundation

/// Finds running headers/footers (chapter titles with page numbers, "Licensed to …" lines, bare page
/// numbers) so read-aloud and the assistant skip them. A line counts if, ignoring digits, it also appears
/// among the first/last lines of a nearby page (±1 or ±2: books alternate left/right headers), or if it is
/// only a page number.
public enum RunningHeaders {
    static let edgeLines = 3

    /// The page text with header/footer lines replaced by spaces. Length (UTF-16) is unchanged, so
    /// offsets into it still match the original page text (PDF selections, speech highlights).
    public static func blanked(_ page: String, neighbours: [String]) -> String {
        let ranges = headerRanges(in: page, neighbours: neighbours)
        guard !ranges.isEmpty else { return page }
        let ns = NSMutableString(string: page)
        for range in ranges {
            ns.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        return ns as String
    }

    /// The page text with header/footer lines removed (for the assistant, where offsets don't matter).
    public static func stripped(_ page: String, neighbours: [String]) -> String {
        blanked(page, neighbours: neighbours)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    static func headerRanges(in page: String, neighbours: [String]) -> [NSRange] {
        let lines = lineRanges(page)
        guard lines.count > 2 else { return [] }
        let edges = Set(neighbours.flatMap { edgeKeys($0) })
        let ns = page as NSString
        var result: [NSRange] = []
        let candidates = Array(lines.prefix(edgeLines)) + Array(lines.suffix(edgeLines))
        for range in Set(candidates.map { RangeKey($0) }).map(\.range) {
            let line = ns.substring(with: range)
            if isPageNumber(line) || (edges.contains(key(line)) && !key(line).isEmpty) {
                result.append(range)
            }
        }
        return result.sorted { $0.location < $1.location }
    }

    /// Keys of the first/last non-empty lines of a page.
    static func edgeKeys(_ page: String) -> [String] {
        let ns = page as NSString
        let lines = lineRanges(page)
        return (lines.prefix(edgeLines) + lines.suffix(edgeLines)).map { key(ns.substring(with: $0)) }
    }

    /// Non-empty lines, in order.
    static func lineRanges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, range, _, _ in
            if let line, !line.trimmingCharacters(in: .whitespaces).isEmpty { ranges.append(range) }
        }
        return ranges
    }

    /// Lowercased, digits and punctuation dropped, whitespace collapsed: "96 CHAPTER 5 Attention…" and
    /// "98 Chapter 5 Attention…" compare equal.
    static func key(_ line: String) -> String {
        line.lowercased().unicodeScalars
            .filter { CharacterSet.letters.contains($0) || $0 == " " }
            .map(String.init).joined()
            .split(separator: " ").joined(separator: " ")
    }

    static func isPageNumber(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        if t.allSatisfy(\.isNumber), !t.isEmpty, t.count <= 4 { return true }
        let roman = Set("ivxlcdm")
        return !t.isEmpty && t.count <= 6 && t.allSatisfy { roman.contains($0) }
    }

    private struct RangeKey: Hashable {
        let range: NSRange
        init(_ range: NSRange) { self.range = range }
        func hash(into hasher: inout Hasher) { hasher.combine(range.location); hasher.combine(range.length) }
        static func == (a: Self, b: Self) -> Bool { a.range == b.range }
    }
}

/// Detects a streamed answer that has started repeating itself (small models can loop indefinitely).
public enum RepetitionGuard {
    /// True if the tail of `text` (a phrase of `window` characters) already occurred `times` times before.
    public static func isLooping(_ text: String, window: Int = 40, times: Int = 3) -> Bool {
        guard text.count > window * (times + 1) else { return false }
        let tail = String(text.suffix(window))
        guard tail.trimmingCharacters(in: .whitespacesAndNewlines).count > window / 2 else { return false }
        var count = 0
        var search = text.startIndex..<text.endIndex
        while let found = text.range(of: tail, range: search) {
            count += 1
            if count > times { return true }
            search = found.upperBound..<text.endIndex
        }
        return false
    }

    /// The text cut back to just after the first occurrence of the repeated phrase.
    public static func trimmed(_ text: String, window: Int = 40) -> String {
        let tail = String(text.suffix(window))
        guard let first = text.range(of: tail) else { return text }
        return String(text[..<first.upperBound]) + " …"
    }
}
