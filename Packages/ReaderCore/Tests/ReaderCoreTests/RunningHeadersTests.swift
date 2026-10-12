import Foundation
import Testing
@testable import ReaderCore

/// Pages laid out like the user's book: even pages "96  CHAPTER 5 Attention is all you need",
/// odd pages "5.1 Transformers  97", and a licence footer on every page.
private func page(_ n: Int, body: String) -> String {
    let header = n % 2 == 0 ? "\(n)\nCHAPTER 5 Attention is all you need" : "5.1 Transformers \(n)"
    return "\(header)\n\(body)\nLicensed to ALEXEY ROMADINOV <reader@example.com>"
}

@Test func runningHeadersAndFootersAreBlankedKeepingOffsets() {
    let p96 = page(96, body: "In 2017, researchers at Google replaced recurrent networks.\nThe Transformer was not the first model.")
    let neighbours = [page(94, body: "Earlier text."), page(95, body: "More."), page(97, body: "Next."), page(98, body: "Later.")]
    let blanked = RunningHeaders.blanked(p96, neighbours: neighbours)
    #expect((blanked as NSString).length == (p96 as NSString).length)          // offsets preserved
    #expect(!blanked.contains("CHAPTER 5") && !blanked.contains("Licensed to") && !blanked.contains("96"))
    #expect(blanked.contains("In 2017, researchers at Google replaced recurrent networks."))
    let stripped = RunningHeaders.stripped(p96, neighbours: neighbours)
    #expect(stripped == "In 2017, researchers at Google replaced recurrent networks.\nThe Transformer was not the first model.")
}

@Test func bodyLinesThatMerelyResembleOthersAreKept() {
    let a = "Introduction\nEntropy measures disorder.\nIt never decreases.\nSummary"
    let b = "Methods\nWe count microstates.\nThen compare.\nResults"
    // Nothing repeats between pages and no line is a page number → nothing removed.
    #expect(RunningHeaders.blanked(a, neighbours: [b]) == a)
}

@Test func loopingAnswersAreDetectedAndTrimmed() {
    let loop = "Softmax turns scores into probabilities. " + String(repeating: "It normalizes the exponentials of the scores so they sum to one. ", count: 6)
    #expect(RepetitionGuard.isLooping(loop))
    let trimmed = RepetitionGuard.trimmed(loop)
    #expect(trimmed.count < loop.count / 2)
    #expect(!RepetitionGuard.isLooping("Softmax turns a vector of scores into a probability distribution. Larger scores get larger probabilities, and all of them sum to one, which is why attention uses it."))
}

@Test func speechStartsFromTappedWord() {
    let paragraphs: [(text: String, anchor: Int)] = [("First paragraph is skipped.", 1),
                                                     ("Entropy never decreases over time.", 2),
                                                     ("Then the next one.", 3)]
    // Offset 10 is inside "never".
    let chunks = SpeechPlanner.chunks(paragraphs, startingAt: (anchor: 2, offset: 10))
    #expect(chunks.map(\.anchor) == [2, 3])
    #expect(chunks[0].text == "never decreases over time.")
    #expect(chunks[0].offset == 8)
    // Unknown anchor (e.g. stale tap): read everything.
    #expect(SpeechPlanner.chunks(paragraphs, startingAt: (anchor: 99, offset: 0)).count == 3)
    #expect(SpeechPlanner.wordStart(in: "a  word", at: 2) == 3)
}

@Test func tapPointMapsToWordOffsetInPageText() {
    let page = PageText(origin: .ocr, lines: [
        [.init(text: "Entropy", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03)),
         .init(text: "rises", rect: CGRect(x: 0.32, y: 0.1, width: 0.12, height: 0.03))],
        [.init(text: "Heat", rect: CGRect(x: 0.1, y: 0.15, width: 0.1, height: 0.03)),
         .init(text: "flows", rect: CGRect(x: 0.22, y: 0.15, width: 0.12, height: 0.03))],
    ])
    let text = page.plainText as NSString                       // "Entropy rises\nHeat flows"
    #expect(page.characterOffset(at: CGPoint(x: 0.35, y: 0.11)) == text.range(of: "rises").location)
    #expect(page.characterOffset(at: CGPoint(x: 0.25, y: 0.165)) == text.range(of: "flows").location)
    #expect(page.characterOffset(at: CGPoint(x: 0.9, y: 0.16)) == text.range(of: "flows").location)   // nearest on line
    #expect(page.characterOffset(at: CGPoint(x: 0.5, y: 0.6)) == nil)
}
