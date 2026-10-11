import ReaderCore
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var serverModels: [String] = []
    @State private var serverStatus: String?
    @State private var testing = false

    private static let ocrLanguageChoices: [(String, String)] = [
        ("en-US", "English"), ("ru-RU", "Russian"), ("uk-UA", "Ukrainian"), ("de-DE", "German"),
        ("fr-FR", "French"), ("es-ES", "Spanish"), ("it-IT", "Italian"), ("pt-BR", "Portuguese"),
        ("zh-Hans", "Chinese (Simplified)"), ("ja-JP", "Japanese"), ("ko-KR", "Korean"),
    ]

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Model", selection: $settings.llm.kind) {
                        ForEach(LLMSettings.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Assistant")
                } footer: {
                    Text(footer(for: settings.llm.kind))
                }

                switch settings.llm.kind {
                case .appleOnDevice:
                    Section("Status") {
                        Label(AppleOnDeviceProvider.unavailableReason ?? "Ready — runs fully on this iPad",
                              systemImage: AppleOnDeviceProvider.unavailableReason == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    }
                case .openAICompatible:
                    Section("Server") {
                        TextField("Base URL", text: $settings.llm.openAIBaseURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        SecureField("API key (optional)", text: $settings.openAIKey)
                        if serverModels.isEmpty {
                            TextField("Model", text: $settings.llm.openAIModel)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        } else {
                            Picker("Model", selection: $settings.llm.openAIModel) {
                                ForEach(serverModels, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Button(testing ? "Connecting…" : "Fetch models") { Task { await fetchModels() } }
                            .disabled(testing)
                        if let serverStatus { Text(serverStatus).font(.footnote).foregroundStyle(.secondary) }
                    }
                case .anthropic:
                    Section("Claude") {
                        SecureField("API key", text: $settings.anthropicKey)
                        Picker("Model", selection: $settings.llm.anthropicModel) {
                            Text("Claude Opus 5.5").tag("claude-opus-5-5")
                            Text("Claude Sonnet 5.5").tag("claude-sonnet-5-5")
                            Text("Claude Haiku 4.5").tag("claude-haiku-4-5")
                        }
                    }
                }

                Section {
                    TextField("Answer language (e.g. English, Russian)", text: $settings.llm.answerLanguage)
                } footer: {
                    Text("Used for answers and the Translate action. Leave empty to answer in the language you ask in.")
                }

                Section {
                    ForEach(Self.ocrLanguageChoices, id: \.0) { code, name in
                        Toggle(name, isOn: Binding(
                            get: { settings.ocrLanguages.contains(code) },
                            set: { on in
                                settings.ocrLanguages.removeAll { $0 == code }
                                if on { settings.ocrLanguages.append(code) }
                            }))
                    }
                } header: {
                    Text("Text recognition languages")
                } footer: {
                    Text("Nothing selected = automatic detection. Order matters: the first selected language is preferred.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func footer(for kind: LLMSettings.Kind) -> String {
        switch kind {
        case .appleOnDevice:
            "Private and offline. Needs an Apple Intelligence–capable iPad. Small model: good for definitions and short explanations."
        case .openAICompatible:
            "Run a model on your Mac or PC and reach it over Wi-Fi. Ollama: `OLLAMA_HOST=0.0.0.0 ollama serve`, URL http://<mac-ip>:11434/v1. LM Studio: enable “Serve on local network”, URL http://<mac-ip>:1234/v1."
        case .anthropic:
            "Best quality for hard texts. Page text and your question are sent to Anthropic."
        }
    }

    private func fetchModels() async {
        testing = true
        defer { testing = false }
        do {
            guard case let provider as OpenAICompatibleProvider = try settings.makeProvider() else { return }
            serverModels = try await provider.availableModels()
            serverStatus = "Connected — \(serverModels.count) model(s)"
            if !serverModels.contains(settings.llm.openAIModel), let first = serverModels.first {
                settings.llm.openAIModel = first
            }
        } catch {
            serverStatus = error.localizedDescription
        }
    }
}
