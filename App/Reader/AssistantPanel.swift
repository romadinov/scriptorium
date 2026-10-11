import ReaderCore
import SwiftUI

struct AssistantPanel: View {
    @Bindable var model: ReaderModel
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
                        EmptyAssistant(hasSelection: !model.selection.isEmpty) { action in
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
            if !model.selection.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "text.quote").foregroundStyle(.secondary)
                    Text(model.selection).lineLimit(3).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear selection", systemImage: "xmark.circle.fill") { model.selection = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom) {
                TextField(model.selection.isEmpty ? "Ask about page \(model.currentPage + 1)…" : "Ask about the selection…",
                          text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(send)
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
            Text(turn.display)
                .padding(10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
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
