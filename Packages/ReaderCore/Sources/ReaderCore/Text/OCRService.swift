import CoreGraphics
import Foundation
import Vision

/// On-device text recognition with the Vision framework.
public struct OCRService: Sendable {
    /// BCP-47 language codes to prefer, e.g. ["en-US", "ru-RU"]. Empty = automatic detection.
    public var languages: [String]

    public init(languages: [String] = []) {
        self.languages = languages
    }

    public static func supportedLanguages() -> [String] {
        RecognizeTextRequest().supportedRecognitionLanguages.map { $0.maximalIdentifier }
    }

    public func recognize(_ image: CGImage) async throws -> PageText {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        }

        let observations = try await request.perform(on: image)
        let lines: [[PageText.Word]] = observations.compactMap { observation -> [PageText.Word]? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let string = candidate.string
            var words: [PageText.Word] = []
            string.enumerateSubstrings(in: string.startIndex..., options: .byWords) { word, range, _, _ in
                guard let word else { return }
                let box = candidate.boundingBox(for: range)?.boundingBox.cgRect ?? observation.boundingBox.cgRect
                words.append(PageText.Word(text: word, rect: Self.flip(box)))
            }
            // Keep punctuation-only lines (e.g. formulas, "—") as a single token.
            if words.isEmpty {
                words = [PageText.Word(text: string, rect: Self.flip(observation.boundingBox.cgRect))]
            }
            return words
        }
        return PageText(origin: .ocr, lines: lines)
    }

    /// Vision uses a bottom-left origin; PageText uses top-left.
    private static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}
