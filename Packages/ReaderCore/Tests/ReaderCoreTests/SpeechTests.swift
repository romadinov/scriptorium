import Foundation
import Testing
@testable import ReaderCore

@Test func speechChunksDetectLanguagePerParagraph() {
    let chunks = SpeechPlanner.chunks([
        ("The second law of thermodynamics states that the total entropy of an isolated system never decreases.", 0),
        ("Энтропия — мера необратимого рассеивания энергии. В изолированной системе она не убывает.", 1),
        ("— 12 —", 2),                     // no letters: skipped
        ("   ", 3),
    ])
    #expect(chunks.map(\.anchor) == [0, 1])
    #expect(chunks.map(\.language) == ["en-US", "ru-RU"])
}

@Test func longParagraphsSplitAtSentences() {
    let sentence = "Entropy measures the number of microscopic configurations. "
    let long = String(repeating: sentence, count: 40)                  // ~2.4k characters
    let chunks = SpeechPlanner.chunks([(long, 7)], maxLength: 600)
    #expect(chunks.count >= 4)
    #expect(chunks.allSatisfy { $0.text.count <= 600 && $0.anchor == 7 })
    #expect(chunks.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).hasSuffix(".") })   // never mid-sentence
    // Offsets point back into the paragraph exactly.
    for chunk in chunks {
        #expect((long as NSString).substring(with: NSRange(location: chunk.offset, length: (chunk.text as NSString).length)) == chunk.text)
    }
}

@Test func sentenceAroundSpokenWord() {
    let text = "First sentence here. Second one is longer. Third."
    let word = (text as NSString).range(of: "longer")
    let sentence = SpeechPlanner.sentence(containing: word, in: text)
    #expect((text as NSString).substring(with: sentence).trimmingCharacters(in: .whitespaces) == "Second one is longer.")
}
