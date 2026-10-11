import Foundation
import Testing
@testable import ReaderCore

/// Manual probe (set PROBE_ON_DEVICE=1): asks the on-device model the user's question several times and reports loops.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PROBE_ON_DEVICE"] == "1"))
func probeSoftmaxExplain() async throws {
    let page = """
    are not hand-coded features. They are learned coordinates in the model's internal representation space. The result is a matrix with one row per token and 512 columns. So when token 4832 is looked up, it is replaced with a 512-dimensional vector such as: [0.12, -0.77, 0.41, ...]
    If the input sentence has multiple tokens (it often does), each one is replaced with its corresponding 512-dimensional vector, which each dimension is a learned feature capturing aspects of meaning or usage. That matrix is the input the encoder receives.
    Each encoder layer begins with a self-attention sublayer. Self-attention allows each token to gather information from other tokens in the same sequence. A concrete example makes the mechanism easier to see. Suppose the input is "How are you?" To update the representation of "are," the model compares "are" with "How," "are," and "you" and asks which of them matters most for interpreting "are" in context. If the resulting weights are 0.2 for "How," 0.1 for "are," and 0.7 for "you," then the new representation of "are" becomes a weighted mixture of those three token representations, dominated by "you." In other words, self-attention turns each token into a context-sensitive summary of the sequence.
    Formally, the model computes these weights using three learned projections of each token representation: a query (Q), a key (K), and a value (V). The query says what the current token is looking for, the key says what each token offers, and the value carries the information that will actually be passed along. The standard formula is as follows:
    Attention(Q, K, V) = softmax( QK^T / √d_k ) V
    Here K^T means the transpose of K, which simply arranges the keys so they can be compared with the queries, and d_k is the size of the key vectors. The scores are then scaled (√d_k) to ensure they remain within a stable range and then passed through a softmax, which ensures their weights that sum to 1, which are then used to average the value vectors.
    """
    let provider = AppleOnDeviceProvider()
    let context = ReadingContext(documentTitle: "Sutskever's_List", pageIndex: 118, selection: "softmax", surroundingText: page)
    for action in [QuickAction.explain, .meaning] {
        for run in 0..<3 {
            let message = ReadingAssistant.firstMessage(question: action.question(selection: "softmax", language: ""), context: context)
            var text = ""
            var looped = false
            for try await delta in provider.stream(system: ReadingAssistant.systemPrompt(answerLanguage: ""),
                                                   messages: [ChatMessage(role: .user, content: message)]) {
                text += delta
                if RepetitionGuard.isLooping(text) { looped = true; break }
            }
            print("PROBE \(action) #\(run) looped=\(looped) chars=\(text.count)\n\(text.prefix(1500))\n-----")
        }
    }
}
