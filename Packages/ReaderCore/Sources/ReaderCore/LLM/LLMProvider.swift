import Foundation

public struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id = UUID()
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public protocol LLMProvider: Sendable {
    var displayName: String { get }
    /// Rough number of characters of document context worth sending. Small on-device models get less.
    var contextCharacterBudget: Int { get }
    /// Streams the assistant reply as text deltas.
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

public enum LLMError: LocalizedError {
    case unavailable(String)
    case http(Int, String)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): why
        case .http(let code, let body): "HTTP \(code): \(body.prefix(400))"
        case .refused(let why): "The model declined: \(why)"
        }
    }
}

/// Persisted provider configuration (API keys live in the Keychain, not here).
public struct LLMSettings: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case appleOnDevice, openAICompatible, anthropic
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .appleOnDevice: "On-device (Apple Intelligence)"
            case .openAICompatible: "Local server (Ollama / LM Studio / OpenAI-compatible)"
            case .anthropic: "Claude (Anthropic API)"
            }
        }
    }

    public var kind: Kind = .appleOnDevice
    public var openAIBaseURL: String = "http://192.168.1.10:11434/v1"
    public var openAIModel: String = "qwen3:8b"
    public var anthropicModel: String = "claude-opus-5-5"
    /// Language for answers and translations; empty = same language as the question.
    public var answerLanguage: String = ""

    public init() {}
}
