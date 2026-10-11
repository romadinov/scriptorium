import ReaderCore
import SwiftUI

struct AssistantPanel: View {
    @Bindable var model: ReaderModel
    var onClose: () -> Void = {}
    @Environment(SettingsStore.self) private var settings
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private var chat: ChatModel { model.chat }

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            header(settings: $settings.llm.kind)
            Divider()
            messages
            if let notice = chat.notice {
                NoticeCard(notice: notice, settings: settings, retry: { model.ask("", action: .summarize, settings: settings) })
                    .padding(.horizontal).padding(.top, 6)
            }
            if let error = chat.error {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal).padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer
        }
    }

    private func header(settings kind: Binding<LLMSettings.Kind>) -> some View {
        HStack {
            Menu {
                Picker("Model", selection: kind) {
                    ForEach(LLMSettings.Kind.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(providerName, systemImage: "sparkles").font(.headline)
            }
            Spacer()
            Button("New chat", systemImage: "square.and.pencil") { chat.clear() }
                .labelStyle(.iconOnly)
                .disabled(chat.turns.isEmpty)
            Button("Close Assistant", systemImage: "xmark") {
                chat.stop()
                onClose()
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("assistant.close")
        }
        .padding()
    }

    private var providerName: String {
        switch settings.llm.kind {
        case .appleOnDevice: "On-device"
        case .openAICompatible: settings.llm.openAIModel
        case .anthropic: settings.llm.anthropicModel
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.turns.isEmpty {
                        EmptyAssistant(hasSelection: !model.questionSelection.isEmpty) { action in
                            model.ask("", action: action, settings: settings)
                        }
                    }
                    ForEach(chat.turns) { turn in
                        TurnView(turn: turn, streaming: chat.isStreaming && turn.id == chat.turns.last?.id)
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: chat.turns.last?.display) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.questionSelection.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "text.quote").foregroundStyle(.secondary)
                    Text(model.questionSelection).lineLimit(3).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear selection", systemImage: "xmark.circle.fill") {
                        model.questionSelection = ""
                        model.selection = ""
                    }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            if !model.questionSelection.isEmpty && !chat.isStreaming {
                // One-tap questions about the selection; "What does it mean?" is the default.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([QuickAction.meaning, .explain, .translate]) { action in
                            Button { model.ask("", action: action, settings: settings) } label: {
                                Label(action.title, systemImage: action.systemImage).font(.callout)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(action == .meaning ? .accentColor : .secondary)
                        }
                    }
                }
            }
            HStack(alignment: .bottom) {
                TextField(model.questionSelection.isEmpty ? "Ask about page \(model.currentPage + 1)…" : "Ask about the selection…",
                          text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(send)
                    // Multi-line fields insert a newline on Return instead of submitting; treat it as Send.
                    .onChange(of: input) { _, text in
                        if text.hasSuffix("\n") {
                            input = String(text.dropLast())
                            send()
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                if chat.isStreaming {
                    Button("Stop", systemImage: "stop.circle.fill") { chat.stop() }
                        .labelStyle(.iconOnly).font(.title2)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                        .labelStyle(.iconOnly).font(.title2)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        input = ""
        model.ask(question, settings: settings)
    }
}

private struct EmptyAssistant: View {
    let hasSelection: Bool
    let onAction: (QuickAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask anything about what you're reading. The current page's text (recognized if needed) is sent along with your question.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(hasSelection ? QuickAction.allCases : [.summarize]) { action in
                Button { onAction(action) } label: { Label(action.title, systemImage: action.systemImage) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical)
    }
}

private struct TurnView: View {
    let turn: ChatModel.Turn
    let streaming: Bool

    var body: some View {
        switch turn.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                Text(turn.display)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                if let context = turn.context {
                    DisclosureGroup("Page text sent (\(context.count) characters)") {
                        Text(context).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if turn.display.isEmpty && streaming {
                    ProgressView()
                } else {
                    MarkdownText(turn.display)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Paragraph-level Markdown: inline styles via AttributedString, plus headings and bullets.
private struct MarkdownText: View {
    let blocks: [String]

    init(_ text: String) {
        blocks = text.components(separatedBy: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("#") {
                    Text(inline(block.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))).font(.headline)
                } else {
                    Text(inline(block))
                }
            }
        }
    }

    private func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }
}

/// Explains why a question wasn't sent and offers the fix.
private struct NoticeCard: View {
    let notice: ChatModel.Notice
    @Bindable var settings: SettingsStore
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch notice {
            case .noText:
                Label("This page has no text yet", systemImage: "doc.text.magnifyingglass").font(.headline)
                Text("It looks like a scan. Use Text › Recognize text on this page, then ask again.")
                    .font(.callout).foregroundStyle(.secondary)
            case .unsupportedLanguage(let language):
                Label("The on-device model can't read \(language)", systemImage: "character.bubble").font(.headline)
                Text("Apple's on-device model supports only some languages and produces nonsense for others. Use a model that understands \(language):")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Local server") { settings.llm.kind = .openAICompatible }
                        .buttonStyle(.borderedProminent)
                    Button("Claude") { settings.llm.kind = .anthropic }
                        .buttonStyle(.bordered)
                }
                Text("Change servers and keys in Settings.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
