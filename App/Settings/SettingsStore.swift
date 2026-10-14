import Foundation
import Observation
import ReaderCore
import Security

/// Settings shared by all your devices (iPad, iPhone, Mac): plain settings through iCloud's key-value
/// store (mirrored in UserDefaults for offline use), API keys through iCloud Keychain.
@MainActor @Observable
final class SettingsStore {
    var llm: LLMSettings {
        didSet {
            // The local server's address is per device (localhost on the Mac, its LAN address on the iPad).
            UserDefaults.standard.set(llm.openAIBaseURL, forKey: "localServerURL")
            if !applyingRemote { save(llm, key: "llmSettings") }
        }
    }

    /// Vision OCR languages (BCP-47). Empty = automatic.
    var ocrLanguages: [String] {
        didSet { if !applyingRemote { store(ocrLanguages, key: "ocrLanguages") } }
    }

    var anthropicKey: String {
        didSet { if !applyingRemote { Keychain.set(anthropicKey, for: "anthropic") } }
    }

    var openAIKey: String {
        didSet { if !applyingRemote { Keychain.set(openAIKey, for: "openai") } }
    }

    /// Your Send to Kindle address (name@kindle.com), for "Send to Kindle".
    var kindleEmail: String {
        didSet { if !applyingRemote { store(kindleEmail.trimmingCharacters(in: .whitespaces), key: "kindleEmail") } }
    }

    @ObservationIgnored private var applyingRemote = false
    @ObservationIgnored private let cloud = NSUbiquitousKeyValueStore.default
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        cloud.synchronize()
        Self.adoptLocalValues(into: cloud)
        var settings = Self.load(LLMSettings.self, key: "llmSettings") ?? LLMSettings()
        if let local = UserDefaults.standard.string(forKey: "localServerURL") { settings.openAIBaseURL = local }
        llm = settings
        ocrLanguages = Self.value(forKey: "ocrLanguages") ?? []
        anthropicKey = Keychain.get("anthropic") ?? ""
        openAIKey = Keychain.get("openai") ?? ""
        kindleEmail = Self.value(forKey: "kindleEmail") ?? ""
        // Another device changed something: take it (without writing it back).
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                          object: cloud, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromCloud() }
        }
    }

    private func reloadFromCloud() {
        applyingRemote = true
        defer { applyingRemote = false }
        for key in ["llmSettings", "ocrLanguages", "kindleEmail"] {
            if let value = cloud.object(forKey: key) { UserDefaults.standard.set(value, forKey: key) }
        }
        if var value = Self.load(LLMSettings.self, key: "llmSettings") {
            value.openAIBaseURL = llm.openAIBaseURL                 // keep this device's server address
            if value != llm { llm = value }
        }
        if let value: [String] = Self.value(forKey: "ocrLanguages"), value != ocrLanguages { ocrLanguages = value }
        if let value: String = Self.value(forKey: "kindleEmail"), value != kindleEmail { kindleEmail = value }
        // Keys arrive through iCloud Keychain on its own schedule; pick up whatever is there now.
        let anthropic = Keychain.get("anthropic") ?? "", openAI = Keychain.get("openai") ?? ""
        if anthropic != anthropicKey { anthropicKey = anthropic }
        if openAI != openAIKey { openAIKey = openAI }
    }

    /// First run with sync: settings made on this device before go up to iCloud (if iCloud has none yet).
    private static func adoptLocalValues(into cloud: NSUbiquitousKeyValueStore) {
        for key in ["llmSettings", "ocrLanguages", "kindleEmail"] where cloud.object(forKey: key) == nil {
            if let local = UserDefaults.standard.object(forKey: key) { cloud.set(local, forKey: key) }
        }
        cloud.synchronize()
    }

    /// iCloud's value if there is one, else this device's.
    private static func value<T>(forKey key: String) -> T? {
        (NSUbiquitousKeyValueStore.default.object(forKey: key) ?? UserDefaults.standard.object(forKey: key)) as? T
    }

    private func store(_ value: Any, key: String) {
        UserDefaults.standard.set(value, forKey: key)
        cloud.set(value, forKey: key)
        cloud.synchronize()
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
        guard let data = try? JSONEncoder().encode(value) else { return }
        store(data, key: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let data = (NSUbiquitousKeyValueStore.default.data(forKey: key)) ?? UserDefaults.standard.data(forKey: key)
        return data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

/// API keys in iCloud Keychain, in a group both apps share, so they sync to all your devices
/// (end-to-end encrypted). Keys saved before (device-only) are moved over when first read.
enum Keychain {
    private static let service = "Reader.apiKeys"
    /// Matches keychain-access-groups in both apps' entitlements ($(TeamIdentifierPrefix)com.romadinov.reader).
    private static let group = "SZVSSCJQFN.com.romadinov.reader"

    private static func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true      // the iOS-style keychain, needed for sync
        #endif
        return query
    }

    /// Before sync: this device only, default group (and on the Mac, the old file keychain).
    private static func legacyQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read(_ query: [String: Any]) -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func get(_ account: String) -> String? {
        if let value = read(query(account)) { return value }
        guard let old = read(legacyQuery(account)) else { return nil }
        set(old, for: account)                                      // move it to iCloud Keychain
        if read(query(account)) == old { SecItemDelete(legacyQuery(account) as CFDictionary) }
        return old
    }

    static func set(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(item as CFDictionary, nil) != errSecSuccess {
            // No shared keychain (e.g. an ad hoc test build): keep it on this device.
            SecItemDelete(legacyQuery(account) as CFDictionary)
            var local = legacyQuery(account)
            local[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(local as CFDictionary, nil)
        }
    }
}
