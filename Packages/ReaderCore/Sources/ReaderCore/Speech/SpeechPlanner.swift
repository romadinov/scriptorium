import AVFoundation
import Foundation
import NaturalLanguage

/// Turns page text into utterance-sized chunks with a detected language, and picks voices.
/// The app speaks one chunk at a time so it can follow along on the page and switch voice per language.
public enum SpeechPlanner {
    public struct Chunk: Equatable, Sendable {
        public var text: String
        /// BCP-47, e.g. "en-US" / "ru-RU"; nil if undetermined.
        public var language: String?
        /// Caller's reference back to where the text came from (paragraph index, page…).
        public var anchor: Int
        /// UTF-16 offset of `text` within the source text, so spoken ranges map back onto the page.
        public var offset: Int

        public init(text: String, language: String?, anchor: Int, offset: Int = 0) {
            self.text = text
            self.language = language
            self.anchor = anchor
            self.offset = offset
        }
    }

    /// One chunk per paragraph; very long paragraphs are split at sentence boundaries so speech
    /// (and the on-page highlight) stays responsive.
    ///
    /// `start` begins reading mid-text: paragraphs before `start.anchor` are skipped and that paragraph is
    /// read from the word containing `start.offset` (UTF-16). Offsets in the chunks stay relative to the
    /// whole paragraph, so highlights still land in the right place.
    public static func chunks(_ paragraphs: [(text: String, anchor: Int)], maxLength: Int = 1200,
                              startingAt start: (anchor: Int, offset: Int)? = nil) -> [Chunk] {
        var result: [Chunk] = []
        var skipping = start != nil && paragraphs.contains { $0.anchor == start!.anchor }
        for (fullText, anchor) in paragraphs {
            var text = fullText
            var base = 0
            if skipping {
                guard anchor == start!.anchor else { continue }
                skipping = false
                base = wordStart(in: fullText, at: start!.offset)
                text = (fullText as NSString).substring(from: base)
            }
            guard text.rangeOfCharacter(from: .letters) != nil else { continue }
            let language = detectLanguage(fullText)
            for piece in segments(text, maxLength: maxLength) where piece.text.rangeOfCharacter(from: .letters) != nil {
                result.append(Chunk(text: piece.text, language: language, anchor: anchor, offset: base + piece.offset))
            }
        }
        return result
    }

    /// UTF-16 offset of the start of the word containing `offset` (or the next word if it's in a gap).
    public static func wordStart(in text: String, at offset: Int) -> Int {
        let ns = text as NSString
        var i = min(max(0, offset), ns.length)
        let letters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’-"))
        func isWordChar(_ index: Int) -> Bool {
            guard index >= 0, index < ns.length, let scalar = UnicodeScalar(ns.character(at: index)) else { return false }
            return letters.contains(scalar)
        }
        if !isWordChar(i) {
            while i < ns.length && !isWordChar(i) { i += 1 }   // tapped between words: take the next one
            return i
        }
        while i > 0 && isWordChar(i - 1) { i -= 1 }
        return i
    }

    public static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        // Only languages we can actually speak, nudged towards the user's own languages — otherwise
        // short Cyrillic text can come back as Kazakh or Bulgarian.
        recognizer.languageConstraints = speakableLanguages
        var hints: [NLLanguage: Double] = [:]
        for (i, preferred) in Locale.preferredLanguages.prefix(4).enumerated() {
            hints[NLLanguage(String(preferred.prefix(2)))] = 0.6 - Double(i) * 0.1
        }
        recognizer.languageHints = hints
        recognizer.processString(String(text.prefix(800)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let code = language.rawValue
        // NaturalLanguage returns bare codes ("en", "ru"); voices want a region.
        let regions = ["en": "en-US", "ru": "ru-RU", "uk": "uk-UA", "de": "de-DE", "fr": "fr-FR", "es": "es-ES",
                       "it": "it-IT", "pt": "pt-BR", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "ja": "ja-JP", "ko": "ko-KR"]
        return regions[code] ?? code
    }

    /// Base languages of the installed voices (e.g. "en", "ru").
    static let speakableLanguages: [NLLanguage] = {
        let codes = Set(AVSpeechSynthesisVoice.speechVoices().map { String($0.language.split(separator: "-").first ?? "") })
        var languages = codes.map(NLLanguage.init(rawValue:))
        if codes.contains("zh") { languages += [.simplifiedChinese, .traditionalChinese] }
        return languages
    }()

    /// Pieces of at most `maxLength` characters, cut only at sentence ends, with their exact UTF-16 offsets.
    public static func segments(_ text: String, maxLength: Int) -> [(text: String, offset: Int)] {
        let whole = NSRange(text.startIndex..., in: text)
        guard text.count > maxLength else { return [(text, 0)] }
        var pieces: [(String, Int)] = []
        var start: String.Index?
        var end = text.startIndex
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let s = start, text.distance(from: s, to: range.upperBound) > maxLength {
                pieces.append((String(text[s..<end]), NSRange(s..<end, in: text).location))
                start = nil
            }
            if start == nil { start = range.lowerBound }
            end = range.upperBound
            return true
        }
        if let s = start { pieces.append((String(text[s..<end]), NSRange(s..<end, in: text).location)) }
        _ = whole
        return pieces
    }

    /// Range of the sentence containing `range` within `text` — the app highlights whole sentences.
    public static func sentence(containing range: NSRange, in text: String) -> NSRange {
        guard let r = Range(range, in: text) else { return range }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let sentence = tokenizer.tokenRange(at: r.lowerBound)
        return NSRange(sentence, in: text)
    }

    /// Best installed voice for a language: Premium, then Enhanced, then default quality.
    public static func bestVoice(for language: String?) -> AVSpeechSynthesisVoice? {
        guard let language else { return nil }
        let base = String(language.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language || $0.language.hasPrefix(base + "-") }
        let exact = voices.filter { $0.language == language }
        let pool = exact.isEmpty ? voices : exact
        return pool.max { a, b in a.quality.rawValue < b.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }
}
