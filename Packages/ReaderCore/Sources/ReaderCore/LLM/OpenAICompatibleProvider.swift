import Foundation

/// Any server speaking the OpenAI chat-completions protocol: Ollama (`http://host:11434/v1`),
/// LM Studio (`http://host:1234/v1`), llama.cpp server, vLLM, OpenRouter, OpenAI itself.
public struct OpenAICompatibleProvider: LLMProvider {
    public var baseURL: URL
    public var model: String
    public var apiKey: String?

    public init(baseURL: URL, model: String, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public var displayName: String { model }
    public var contextCharacterBudget: Int { 24_000 }

    public func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 600

        let wire = [["role": "system", "content": system]] + messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let body: [String: Any] = ["model": model, "stream": true, "messages": wire, "temperature": 0.2]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return SSE.deltas(for: request) { json in
            if let error = json["error"] as? [String: Any] {
                throw LLMError.unavailable(error["message"] as? String ?? "Server error")
            }
            let choices = json["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            return delta?["content"] as? String
        }
    }

    /// Lists models the server exposes (`GET /models`). Used to populate the model picker.
    public func availableModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = json?["data"] as? [[String: Any]] ?? []
        return models.compactMap { $0["id"] as? String }.sorted()
    }
}
