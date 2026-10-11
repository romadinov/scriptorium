import Foundation

/// Claude via the Messages API (raw HTTP + SSE; there is no official Swift SDK).
public struct AnthropicProvider: LLMProvider {
    public var apiKey: String
    public var model: String
    /// `low` keeps quick look-ups snappy; reading questions rarely need deep reasoning.
    public var effort: String

    public init(apiKey: String, model: String = "claude-opus-5-5", effort: String = "low") {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
    }

    public var displayName: String { model }
    public var contextCharacterBudget: Int { 120_000 }

    public func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // On a safety-classifier decline, let the API re-run the request on a fallback model.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16_000,
            "stream": true,
            "system": system,
            "output_config": ["effort": effort],
            "fallbacks": "default",
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return SSE.deltas(for: request) { json in
            switch json["type"] as? String {
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any]
                return delta?["type"] as? String == "text_delta" ? delta?["text"] as? String : nil
            case "message_delta":
                let delta = json["delta"] as? [String: Any]
                if delta?["stop_reason"] as? String == "refusal" {
                    let details = delta?["stop_details"] as? [String: Any]
                    throw LLMError.refused(details?["explanation"] as? String ?? "request declined")
                }
                return nil
            case "error":
                let error = json["error"] as? [String: Any]
                throw LLMError.unavailable(error?["message"] as? String ?? "Anthropic API error")
            default:
                return nil
            }
        }
    }
}
