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
