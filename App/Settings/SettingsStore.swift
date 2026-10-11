import Foundation
import Observation
import ReaderCore
import Security

@MainActor @Observable
final class SettingsStore {
    var llm: LLMSettings {
        didSet { save(llm, key: "llmSettings") }
    }

    /// Vision OCR languages (BCP-47). Empty = automatic.
    var ocrLanguages: [String] {
        didSet { UserDefaults.standard.set(ocrLanguages, forKey: "ocrLanguages") }
    }

    var anthropicKey: String {
        didSet { Keychain.set(anthropicKey, for: "anthropic") }
    }

    var openAIKey: String {
        didSet { Keychain.set(openAIKey, for: "openai") }
    }

    init() {
        llm = Self.load(LLMSettings.self, key: "llmSettings") ?? LLMSettings()
        ocrLanguages = UserDefaults.standard.stringArray(forKey: "ocrLanguages") ?? []
        anthropicKey = Keychain.get("anthropic") ?? ""
        openAIKey = Keychain.get("openai") ?? ""
    }

    func makeProvider() throws -> LLMProvider {
        switch llm.kind {
        case .appleOnDevice:
            if let reason = AppleOnDeviceProvider.unavailableReason { throw LLMError.unavailable(reason) }
            return AppleOnDeviceProvider()
        case .openAICompatible:
            guard let url = URL(string: llm.openAIBaseURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
                throw LLMError.unavailable("Set the server URL in Settings, e.g. http://192.168.1.10:11434/v1")
            }
            return OpenAICompatibleProvider(baseURL: url, model: llm.openAIModel, apiKey: openAIKey)
        case .anthropic:
            guard !anthropicKey.isEmpty else { throw LLMError.unavailable("Add your Anthropic API key in Settings.") }
            return AnthropicProvider(apiKey: anthropicKey, model: llm.anthropicModel)
        }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

enum Keychain {
    private static let service = "Reader.apiKeys"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
