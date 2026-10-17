import Foundation

/// A passage identified by its text and a little context either side (like the W3C TextQuoteSelector):
/// it survives reflow, re-pagination and font changes, where offsets don't.
public struct TextQuote: Equatable, Sendable {
    public static let maxLength = 200
    public static let contextLength = 32

    public var exact: String
    public var prefix: String
    public var suffix: String

    public init(exact: String, prefix: String = "", suffix: String = "") {
        self.exact = exact
        self.prefix = prefix
        self.suffix = suffix
    }

    /// The quote for `selection` within `text` (the page or chapter), with context taken from `text`.
    /// Long selections keep their first `maxLength` characters: enough to find the place.
    public init(selection: String, in text: String) {
        let exact = String(Self.squash(selection).prefix(Self.maxLength))
        let flat = Self.collapse(text)
        guard let range = flat.range(of: exact) else {
            self.init(exact: exact)
            return
        }
        self.init(exact: exact,
                  prefix: String(flat[..<range.lowerBound].suffix(Self.contextLength)),
                  suffix: String(flat[range.upperBound...].prefix(Self.contextLength)))
    }

    /// Where the quote is in `text` (whitespace-insensitive): the occurrence whose context matches best.
    /// Offsets are in `text`'s own characters.
    public func locate(in text: String) -> Range<String.Index>? {
        // Search in a whitespace-squashed copy, keeping a map back to the original characters.
        var flat = "", map: [String.Index] = []
        var lastWasSpace = true
        for i in text.indices {
            if text[i].isWhitespace {
                if !lastWasSpace { flat.append(" "); map.append(i) }
                lastWasSpace = true
            } else {
                flat.append(text[i]); map.append(i)
                lastWasSpace = false
            }
        }
        let target = Self.squash(exact)
        guard !target.isEmpty else { return nil }
        var best: (score: Int, range: Range<String.Index>)?
        var from = flat.startIndex
        while let found = flat.range(of: target, range: from..<flat.endIndex) {
            let before = String(flat[..<found.lowerBound].suffix(prefix.count))
            let after = String(flat[found.upperBound...].prefix(suffix.count))
            let score = Self.overlap(before, Self.collapse(prefix), fromEnd: true) + Self.overlap(after, Self.collapse(suffix), fromEnd: false)
            if best == nil || score > best!.score { best = (score, found) }
            from = flat.index(after: found.lowerBound)
        }
        guard let range = best?.range else { return nil }
        let start = map[flat.distance(from: flat.startIndex, to: range.lowerBound)]
        let lastIndex = map[flat.distance(from: flat.startIndex, to: range.upperBound) - 1]
        return start..<text.index(after: lastIndex)
    }

    /// Whitespace runs as single spaces, edges kept (context next to the quote starts or ends with a space).
    static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func squash(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Matching characters counted from the side next to the quote.
    private static func overlap(_ a: String, _ b: String, fromEnd: Bool) -> Int {
        let x = fromEnd ? Array(a.reversed()) : Array(a), y = fromEnd ? Array(b.reversed()) : Array(b)
        var n = 0
        while n < min(x.count, y.count), x[n] == y[n] { n += 1 }
        return n
    }
}
