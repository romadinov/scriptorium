import Foundation
import FoundationModels

/// Apple's on-device foundation model (Apple Intelligence). Fully offline and free,
/// but small (~4K-token context), so the prompt carries only a little document text.
public struct AppleOnDeviceProvider: LLMProvider {
    public init() {}

    public var displayName: String { "Apple on-device" }
    public var contextCharacterBudget: Int { 5_000 }

    /// `nil` when the model can be used; otherwise a human-readable reason.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This device does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in Settings."
        case .unavailable(.modelNotReady): "The on-device model is still downloading."
        case .unavailable: "The on-device model is unavailable."
        }
    }

    public func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = Self.unavailableReason { throw LLMError.unavailable(reason) }
                    let session = LanguageModelSession(instructions: system)
                    // The session API is turn-based; fold earlier turns into the prompt.
                    let prompt = Self.flatten(messages)
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: prompt) {
                        let full = snapshot.content
                        if full.hasPrefix(emitted) {
                            continuation.yield(String(full.dropFirst(emitted.count)))
                        }
                        emitted = full
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func flatten(_ messages: [ChatMessage]) -> String {
        guard messages.count > 1 else { return messages.last?.content ?? "" }
        // The context window is ~4K tokens: keep the first turn (it carries the page text) and the latest exchange.
        let earlier = messages.dropLast()
        let kept = earlier.count <= 3 ? Array(earlier) : [earlier.first!] + earlier.suffix(2)
        let history = kept.map { "\($0.role == .user ? "User" : "Assistant"): \($0.content)" }
        return "Conversation so far:\n" + history.joined(separator: "\n\n") + "\n\nUser: " + (messages.last?.content ?? "")
    }
}
