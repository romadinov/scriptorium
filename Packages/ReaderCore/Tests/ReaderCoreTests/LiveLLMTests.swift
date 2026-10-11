import Foundation
import Testing
@testable import ReaderCore

/// Hit real models. Opt in with READER_LIVE_LLM=1 (needs Ollama on localhost / Apple Intelligence).
private let live = ProcessInfo.processInfo.environment["READER_LIVE_LLM"] == "1"

private func collect(_ provider: LLMProvider) async throws -> String {
    let context = ReadingContext(documentTitle: "Physics", pageIndex: 0, selection: "entropy",
                                 surroundingText: "The entropy of an isolated system never decreases.")
    let message = ReadingAssistant.firstMessage(question: "Define the selection in one sentence.", context: context)
    var reply = ""
    for try await delta in provider.stream(system: ReadingAssistant.systemPrompt(answerLanguage: "English"),
                                           messages: [ChatMessage(role: .user, content: message)]) {
        reply += delta
    }
    return reply
}

@Test(.enabled(if: live)) func ollamaStreamsAnswer() async throws {
    let provider = OpenAICompatibleProvider(baseURL: URL(string: "http://localhost:11434/v1")!, model: "")
    let models = try await provider.availableModels()
    let model = try #require(models.first { !$0.contains("cloud") })
    let reply = try await collect(OpenAICompatibleProvider(baseURL: provider.baseURL, model: model))
    print("[\(model)] \(reply)")
    #expect(reply.localizedCaseInsensitiveContains("disorder") || reply.localizedCaseInsensitiveContains("entropy"))
}

@Test(.enabled(if: live && AppleOnDeviceProvider.unavailableReason == nil)) func appleOnDeviceStreamsAnswer() async throws {
    let reply = try await collect(AppleOnDeviceProvider())
    print("[apple] \(reply)")
    #expect(!reply.isEmpty)
}

@Test(.enabled(if: live)) func badServerSurfacesHTTPError() async {
    let provider = OpenAICompatibleProvider(baseURL: URL(string: "http://localhost:11434/v1")!, model: "no-such-model-xyz")
    await #expect(throws: LLMError.self) { _ = try await collect(provider) }
}
