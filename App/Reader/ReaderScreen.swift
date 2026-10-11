import ReaderCore
import SwiftUI
import Translation

struct ReaderScreen: View {
    let book: Book
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @State private var model: ReaderModel?
    @State private var openError: String?

    var body: some View {
        Group {
            if let model {
                ReaderContent(model: model)
            } else if let openError {
                ContentUnavailableView("Can't open \(book.title)", systemImage: "exclamationmark.triangle", description: Text(openError))
            } else {
                ProgressView()
            }
        }
        .task(id: book.url) {
            do {
                model = try await ReaderModel.load(book: book, startPage: library.lastPage(book),
                                                   startProgress: library.lastProgress(book),
                                                   ocrLanguages: settings.ocrLanguages,
                                                   highlightStore: HighlightStore.shared)
            } catch {
                openError = error.localizedDescription
            }
        }
        .onChange(of: model?.currentPage) { _, page in
            if let page { library.setLastPage(page, for: book) }
        }
        .onChange(of: model?.pageProgress) { _, progress in
            if let progress { library.setLastProgress(progress, for: book) }
        }
        .onChange(of: settings.ocrLanguages) { _, languages in
            guard let text = model?.text else { return }
            Task { await text.setLanguages(languages) }
        }
    }
}

private struct ReaderContent: View {
    @Bindable var model: ReaderModel
    @Environment(SettingsStore.self) private var settings
    @State private var showAssistant = false
    @State private var showOutline = false
    @State private var showPagePicker = false
    @State private var dictionaryTerm: DictionaryTerm?
    @State private var showTranslation = false
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("reflowLayout") private var layout: ReflowLayout = .paged
    @State private var showHighlights = false

    var body: some View {
        ZStack(alignment: .bottom) {
            viewer
                .ignoresSafeArea(edges: .bottom)
                .id(model.imageMode)

            VStack(spacing: 8) {
                if let status = model.statusMessage {
                    StatusPill(text: status) { model.statusMessage = nil }
                }
                if let progress = model.ocrProgress {
                    OCRProgressPill(progress: progress) { model.cancelRecognition() }
                }
                if !model.selection.isEmpty {
                    SelectionBar(
                        selection: model.selection,
                        onAction: { action in
                            showAssistant = true
                            model.ask("", action: action, settings: settings)
                        },
                        onAsk: { showAssistant = true },
                        onDictionary: { dictionaryTerm = DictionaryTerm(text: model.selection) },
                        onTranslate: { showTranslation = true },
                        onHighlight: { color in Task { await model.addHighlight(color: color) } })
                }
            }
            .padding(.bottom, 20)
            .padding(.horizontal)
            .animation(.snappy, value: model.selection.isEmpty)
        }
        .navigationTitle(model.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .inspector(isPresented: $showAssistant) {
            AssistantPanel(model: model)
                .inspectorColumnWidth(min: 320, ideal: 420, max: 600)
        }
        .sheet(item: $dictionaryTerm) { term in
            DictionaryView(term: term.text).ignoresSafeArea()
        }
        .modifier(AppleTranslation(isPresented: $showTranslation, text: model.selection))
        .confirmationDialog("Highlight", isPresented: Binding(get: { model.tappedHighlight != nil },
                                                              set: { if !$0 { model.tappedHighlight = nil } }),
                            presenting: model.tappedHighlight) { highlight in
            ForEach(Highlight.Color.allCases.filter { $0 != highlight.color }, id: \.self) { color in
                Button("Make \(color.rawValue)") { Task { await model.recolor(highlight, to: color) } }
            }
            Button("Ask the assistant about it") {
                model.selection = highlight.text
                showAssistant = true
                model.ask("", action: .explain, settings: settings)
            }
            Button("Remove highlight", role: .destructive) { Task { await model.removeHighlight(highlight) } }
        } message: { highlight in
            Text("“\(highlight.text.prefix(140))”")
        }
    }

    @ViewBuilder
    private var viewer: some View {
        if let book = model.reflowable {
            ReflowableView(model: model, book: book, layout: layout, fontScale: fontScale)
                .id(layout)
        } else if model.imageMode || model.pdfDocument == nil {
            PagedImageView(model: model)
        } else {
            PDFKitView(model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if !model.source.outline.isEmpty {
                Button("Contents", systemImage: "list.bullet") { showOutline = true }
                    .popover(isPresented: $showOutline) {
                        OutlineView(items: model.source.outline) { page in
                            model.go(to: page)
                            showOutline = false
                        }
                        .frame(minWidth: 320, minHeight: 400)
                    }
            }
            if model.reflowable != nil {
                Button("Previous chapter", systemImage: "chevron.left") { model.go(to: model.currentPage - 1) }
                    .disabled(model.currentPage == 0)
            }
            Button(pageLabel) { showPagePicker = true }
                .monospacedDigit()
                .popover(isPresented: $showPagePicker) {
                    PagePicker(model: model).padding().frame(width: 320)
                }
            if model.reflowable != nil {
                Button("Next chapter", systemImage: "chevron.right") { model.go(to: model.currentPage + 1) }
                    .disabled(model.currentPage >= model.source.pageCount - 1)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.reflowable != nil {
                Menu("Reading options", systemImage: "textformat.size") {
                    Picker("Layout", selection: $layout) {
                        ForEach(ReflowLayout.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    Section("Text size") {
                        Button("Larger", systemImage: "plus.magnifyingglass") { fontScale = min(2.0, fontScale + 0.1) }
                        Button("Smaller", systemImage: "minus.magnifyingglass") { fontScale = max(0.7, fontScale - 0.1) }
                        Button("Default size", systemImage: "arrow.counterclockwise") { fontScale = 1.0 }
                    }
                }
            } else {
                Menu("Text", systemImage: "text.viewfinder") {
                    Button("Recognize text on this page", systemImage: "doc.text.viewfinder") { model.recognizeCurrentPage() }
                    Button("Recognize whole document", systemImage: "doc.on.doc") { model.recognizeDocument() }
                    if model.pdfDocument != nil {
                        Divider()
                        Toggle(isOn: $model.imageMode) {
                            Label("Live Text mode (for scans)", systemImage: "camera.viewfinder")
                        }
                    }
                }
            }
            Button("Highlights", systemImage: "highlighter") { showHighlights = true }
                .popover(isPresented: $showHighlights) {
                    HighlightsList(model: model) { highlight in
                        showHighlights = false
                        model.reveal(highlight)
                    }
                    .frame(minWidth: 360, minHeight: 440)
                }
            Button("Assistant", systemImage: "sparkles") { showAssistant.toggle() }
        }
    }

    private var pageLabel: String {
        let total = model.source.pageCount
        guard model.reflowable != nil else { return "\(model.currentPage + 1) / \(total)" }
        if let sub = model.subPage, layout == .paged {
            return "Ch. \(model.currentPage + 1) / \(total) · \(sub.page)/\(sub.pages)"
        }
        return "Ch. \(model.currentPage + 1) / \(total)"
    }
}

private struct HighlightsList: View {
    let model: ReaderModel
    let onSelect: (Highlight) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.highlights.isEmpty {
                    ContentUnavailableView("No highlights yet", systemImage: "highlighter",
                                           description: Text("Select text and tap Highlight."))
                } else {
                    List {
                        ForEach(model.highlights) { highlight in
                            Button { onSelect(highlight) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    RoundedRectangle(cornerRadius: 2).fill(highlight.color.swiftUI).frame(width: 4)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(highlight.text).lineLimit(5).foregroundStyle(.primary)
                                        Text(model.locationLabel(highlight.location))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            let doomed = offsets.map { model.highlights[$0] }
                            Task { for h in doomed { await model.removeHighlight(h) } }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Highlights")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if !model.highlightLocationDescription.isEmpty {
                    Text("Saved as text in \(model.highlightLocationDescription)")
                        .font(.footnote).foregroundStyle(.secondary).padding(8)
                }
            }
        }
    }
}

extension Highlight.Color {
    var swiftUI: Color {
        let (r, g, b) = rgb
        return Color(red: r, green: g, blue: b)
    }
}

/// On-device Apple Translation sheet (not available in Mac Catalyst, which `scripts/typecheck.sh` builds against).
private struct AppleTranslation: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        content.translationPresentation(isPresented: $isPresented, text: text)
        #endif
    }
}

struct DictionaryTerm: Identifiable {
    let text: String
    var id: String { text }
}

private struct SelectionBar: View {
    let selection: String
    let onAction: (QuickAction) -> Void
    let onAsk: () -> Void
    let onDictionary: () -> Void
    let onTranslate: () -> Void
    let onHighlight: (Highlight.Color) -> Void

    private var isShort: Bool { selection.split(whereSeparator: \.isWhitespace).count <= 3 }

    var body: some View {
        // Full labels when there is room; icons only when the assistant panel squeezes the reader.
        ViewThatFits(in: .horizontal) {
            buttons(showTitles: true)
            buttons(showTitles: false)
        }
        .padding(6)
        .glassEffect(in: .capsule)
    }

    private func buttons(showTitles: Bool) -> some View {
        HStack(spacing: 4) {
            bar("Highlight", "highlighter", showTitles) { onHighlight(.yellow) }
                .contextMenu {
                    ForEach(Highlight.Color.allCases, id: \.self) { color in
                        Button(color.rawValue.capitalized) { onHighlight(color) }
                    }
                }
            Divider().frame(height: 24)
            if isShort {
                bar("Dictionary", "book", showTitles, action: onDictionary)
                bar("Define", "character.book.closed", showTitles) { onAction(.define) }
            } else {
                bar("Explain", "lightbulb", showTitles) { onAction(.explain) }
            }
            bar("Translate", "translate", showTitles) { onAction(.translate) }
            bar("Apple Translate", "globe", showTitles, action: onTranslate)
            Divider().frame(height: 24)
            bar("Ask…", "sparkles", showTitles, action: onAsk)
        }
        .fixedSize()
    }

    private func bar(_ title: String, _ image: String, _ showTitle: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: image)
                .labelStyle(TitleAndIconOrIcon(showTitle: showTitle))
                .font(.callout).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct TitleAndIconOrIcon: LabelStyle {
    let showTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showTitle {
            Label(configuration)
        } else {
            configuration.icon
        }
    }
}

private struct StatusPill: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(text).font(.callout)
            Button("Dismiss", systemImage: "xmark", action: onClose).labelStyle(.iconOnly).buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(in: .capsule)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(4))
            onClose()
        }
    }
}

private struct OCRProgressPill: View {
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: progress).frame(width: 160)
            Text("Recognizing \(Int(progress * 100))%").font(.callout).monospacedDigit()
            Button("Stop", action: onCancel).buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(in: .capsule)
    }
}

private struct PagePicker: View {
    let model: ReaderModel
    @State private var value: Double = 0
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.reflowable == nil ? "Page" : "Chapter") \(Int(value) + 1) of \(model.source.pageCount)")
                .font(.headline).monospacedDigit()
            Slider(value: $value, in: 0...Double(max(1, model.source.pageCount - 1)), step: 1) { editing in
                if !editing { model.go(to: Int(value)) }
            }
            HStack {
                TextField(model.reflowable == nil ? "Go to page" : "Go to chapter", text: $typed).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    .onSubmit(go)
                Button("Go", action: go).buttonStyle(.borderedProminent)
            }
        }
        .onAppear { value = Double(model.currentPage) }
    }

    private func go() {
        guard let page = Int(typed) else { return }
        model.go(to: page - 1)
        value = Double(page - 1)
    }
}

private struct OutlineView: View {
    let items: [OutlineItem]
    let onSelect: (Int) -> Void

    var body: some View {
        List {
            OutlineGroup(items, children: \.childrenOrNil) { item in
                Button {
                    if let page = item.pageIndex { onSelect(page) }
                } label: {
                    HStack {
                        Text(item.title).foregroundStyle(.primary)
                        Spacer()
                        if let page = item.pageIndex { Text("\(page + 1)").foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
                .disabled(item.pageIndex == nil)
            }
        }
        .listStyle(.plain)
    }
}

extension OutlineItem {
    var childrenOrNil: [OutlineItem]? { children.isEmpty ? nil : children }
}

/// System dictionary (Settings › General › Dictionary lets you add more languages).
struct DictionaryView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}
