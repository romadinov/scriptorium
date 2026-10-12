import ReaderCore
import SwiftUI

/// Scriptorium › Settings… (⌘,)
struct MacSettingsView: View {
    var body: some View {
        TabView {
            AssistantSettings().tabItem { Label("Assistant", systemImage: "sparkles") }
            RecognitionSettings().tabItem { Label("Text Recognition", systemImage: "text.viewfinder") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct AssistantSettings: View {
    @Environment(SettingsStore.self) private var settings
    @State private var serverModels: [String] = []
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Model", selection: $settings.llm.kind) {
                ForEach(LLMSettings.Kind.allCases) { Text($0.title).tag($0) }
            }
            switch settings.llm.kind {
            case .appleOnDevice:
                LabeledContent("Status", value: AppleOnDeviceProvider.unavailableReason ?? "Ready — runs on this Mac")
            case .openAICompatible:
                TextField("Server URL", text: $settings.llm.openAIBaseURL, prompt: Text("http://localhost:11434/v1"))
                SecureField("API key (optional)", text: $settings.openAIKey)
                if serverModels.isEmpty {
                    TextField("Model", text: $settings.llm.openAIModel)
                } else {
                    Picker("Model", selection: $settings.llm.openAIModel) {
                        ForEach(serverModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                HStack {
                    Button(testing ? "Connecting…" : "Fetch Models") { Task { await fetchModels() } }.disabled(testing)
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            case .anthropic:
                SecureField("API key", text: $settings.anthropicKey)
                Picker("Model", selection: $settings.llm.anthropicModel) {
                    Text("Claude Opus 5.5").tag("claude-opus-5-5")
                    Text("Claude Sonnet 5.5").tag("claude-sonnet-5-5")
                    Text("Claude Haiku 4.5").tag("claude-haiku-4-5")
                }
            }
            TextField("Answer language", text: $settings.llm.answerLanguage, prompt: Text("Same as the question"))
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var footer: String {
        switch settings.llm.kind {
        case .appleOnDevice: "Private and offline, using Apple Intelligence on this Mac. Good for definitions and short explanations; doesn't support every language."
        case .openAICompatible: "Ollama or LM Studio on this Mac: http://localhost:11434/v1 (Ollama) or http://localhost:1234/v1 (LM Studio)."
        case .anthropic: "Best quality for hard texts. Page text and your question are sent to Anthropic."
        }
    }

    private func fetchModels() async {
        testing = true
        defer { testing = false }
        do {
            guard case let provider as OpenAICompatibleProvider = try settings.makeProvider() else { return }
            serverModels = try await provider.availableModels()
            status = "Connected — \(serverModels.count) model(s)"
            if !serverModels.contains(settings.llm.openAIModel), let first = serverModels.first { settings.llm.openAIModel = first }
        } catch {
            status = error.localizedDescription
        }
    }
}

private struct RecognitionSettings: View {
    @Environment(SettingsStore.self) private var settings
    private static let choices: [(String, String)] = [
        ("en-US", "English"), ("ru-RU", "Russian"), ("uk-UA", "Ukrainian"), ("de-DE", "German"),
        ("fr-FR", "French"), ("es-ES", "Spanish"), ("it-IT", "Italian"), ("pt-BR", "Portuguese"),
        ("zh-Hans", "Chinese (Simplified)"), ("ja-JP", "Japanese"), ("ko-KR", "Korean"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.choices, id: \.0) { code, name in
                    Toggle(name, isOn: Binding(
                        get: { settings.ocrLanguages.contains(code) },
                        set: { on in
                            settings.ocrLanguages.removeAll { $0 == code }
                            if on { settings.ocrLanguages.append(code) }
                        }))
                }
            } footer: {
                Text("For scanned books. Nothing selected = automatic detection; the first selected language is preferred.")
            }
        }
        .formStyle(.grouped)
    }
}
