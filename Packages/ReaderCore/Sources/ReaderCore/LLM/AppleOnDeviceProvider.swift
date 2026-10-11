import Foundation
import FoundationModels

/// Apple's on-device foundation model (Apple Intelligence). Fully offline and free,
/// but small (~4K-token context), so the prompt carries only a little document text.
public struct AppleOnDeviceProvider: LLMProvider {
    public init() {}

    public var displayName: String { "Apple on-device" }
    // ~4K-token window shared by instructions, page text, question and answer.
    public var contextCharacterBudget: Int { 3_500 }

    /// Whether the on-device model understands text in this language (BCP-47, e.g. "ru-RU").
    /// It supports a fixed set (no Russian, Ukrainian, Polish…); unsupported text produces confident junk.
    public static func supports(language: String) -> Bool {
        SystemLanguageModel.default.supportsLocale(Locale(identifier: language))
    }

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
                    // Low temperature: reading questions want faithful answers, not creative ones.
                    // A response cap stops a runaway (looping) answer from filling the context window.
                    let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 700)
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
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
