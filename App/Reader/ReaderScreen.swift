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
        .task(id: model == nil) {
            // Arrived through a highlight link: show it once the viewer has laid out.
            guard let model, let id = library.pendingHighlight,
                  let highlight = model.highlights.first(where: { $0.id == id }) else { return }
            library.pendingHighlight = nil
            try? await Task.sleep(for: .seconds(1))
            model.reveal(highlight)
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
    @AppStorage("pageTurning") private var turning: PageTurning = .horizontal
    @State private var showHighlights = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPhone (and narrow iPad split view): fewer toolbar buttons, panels as sheets.
    private var compact: Bool { sizeClass == .compact }

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
                if model.readAloud.state != .idle {
                    ReadAloudBar(readAloud: model.readAloud)
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
        .overlay(alignment: .top) {
            if let back = model.backStack.last {
                BackPill(label: back.label, depth: model.backStack.count,
                         onBack: { model.goBack() }, onDismiss: { model.clearBackStack() })
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.backStack.count)
        .onDisappear { model.readAloud.stop() }
        .navigationTitle(model.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if compact { compactToolbar } else { toolbar }
        }
        .sheet(isPresented: compactOnly($showOutline)) {
            NavigationStack {
                OutlineView(items: model.source.outline) { page in
                    model.go(to: page)
                    showOutline = false
                }
                .navigationTitle("Contents").navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: compactOnly($showPagePicker)) {
            PagePicker(model: model).padding().presentationDetents([.height(260)])
        }
        .sheet(isPresented: compactOnly($showHighlights)) {
            HighlightsList(model: model, onSelect: { highlight in
                showHighlights = false
                model.reveal(highlight)
            }, onSelectBookmark: { bookmark in
                showHighlights = false
                model.open(bookmark)
            })
        }
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
            ReflowableView(model: model, book: book, layout: effectiveLayout, fontScale: fontScale)
                .id(effectiveLayout)
        } else if model.imageMode || model.pdfDocument == nil {
            if turning == .horizontal {
                HorizontalPageView(model: model).id(turning)
            } else {
                PagedImageView(model: model).id(turning)
            }
        } else {
            PDFKitView(model: model, turning: turning).id(turning)
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
            if model.reflowable != nil && model.source.pageCount > 1 {
                Button("Previous chapter", systemImage: "chevron.left") { model.go(to: model.currentPage - 1, remember: false) }
                    .disabled(model.currentPage == 0)
            }
            Button(pageLabel) { showPagePicker = true }
                .monospacedDigit()
                .accessibilityLabel(pageAccessibilityLabel)
                .popover(isPresented: $showPagePicker) {
                    PagePicker(model: model).padding().frame(width: 320)
                }
            if model.reflowable != nil && model.source.pageCount > 1 {
                Button("Next chapter", systemImage: "chevron.right") { model.go(to: model.currentPage + 1, remember: false) }
                    .disabled(model.currentPage >= model.source.pageCount - 1)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.reflowable != nil {
                Menu("Reading options", systemImage: "textformat.size") {
                    if !(model.source is WebArchiveSource) {
                        Picker("Layout", selection: $layout) {
                            ForEach(ReflowLayout.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                        }
                    }
                    Section("Text size") {
                        Button("Larger", systemImage: "plus.magnifyingglass") { fontScale = min(2.0, fontScale + 0.1) }
                        Button("Smaller", systemImage: "minus.magnifyingglass") { fontScale = max(0.7, fontScale - 0.1) }
                        Button("Default size", systemImage: "arrow.counterclockwise") { fontScale = 1.0 }
                    }
                }
            } else {
                Menu("Page layout", systemImage: turning.systemImage) {
                    Picker("Page turning", selection: $turning) {
                        ForEach(PageTurning.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                }
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
            Button(model.currentBookmark == nil ? "Bookmark this page" : "Remove bookmark",
                   systemImage: model.currentBookmark == nil ? "bookmark" : "bookmark.fill") {
                Task { await model.toggleBookmark() }
            }
            Button(model.readAloud.state == .idle ? "Read aloud" : "Stop reading aloud",
                   systemImage: model.readAloud.state == .idle ? "speaker.wave.2" : "speaker.slash") {
                if model.readAloud.state == .idle { model.readAloud.start(model) } else { model.readAloud.stop() }
            }
            Button("Highlights", systemImage: "highlighter") { showHighlights = true }
                .popover(isPresented: $showHighlights) {
                    HighlightsList(model: model, onSelect: { highlight in
                        showHighlights = false
                        model.reveal(highlight)
                    }, onSelectBookmark: { bookmark in
                        showHighlights = false
                        model.open(bookmark)
                    })
                    .frame(minWidth: 360, minHeight: 440)
                }
            Button("Assistant", systemImage: "sparkles") { showAssistant.toggle() }
        }
    }

    /// On iPhone these panels are sheets on the root view (the iPad popovers hang off toolbar buttons).
    private func compactOnly(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { compact && binding.wrappedValue }, set: { binding.wrappedValue = $0 })
    }

    @ToolbarContentBuilder
    private var compactToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if !model.source.outline.isEmpty {
                Button("Contents", systemImage: "list.bullet") { showOutline = true }
            }
            Button(pageLabel) { showPagePicker = true }
                .monospacedDigit()
                .accessibilityLabel(pageAccessibilityLabel)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(model.currentBookmark == nil ? "Bookmark this page" : "Remove bookmark",
                   systemImage: model.currentBookmark == nil ? "bookmark" : "bookmark.fill") {
                Task { await model.toggleBookmark() }
            }
            Button("Assistant", systemImage: "sparkles") { showAssistant.toggle() }
            Menu("More", systemImage: "ellipsis.circle") {
                Button(model.readAloud.state == .idle ? "Read aloud" : "Stop reading aloud",
                       systemImage: model.readAloud.state == .idle ? "speaker.wave.2" : "speaker.slash") {
                    if model.readAloud.state == .idle { model.readAloud.start(model) } else { model.readAloud.stop() }
                }
                Button("Highlights & Bookmarks", systemImage: "highlighter") { showHighlights = true }
                if model.reflowable != nil && model.source.pageCount > 1 {
                    Section {
                        Button("Previous chapter", systemImage: "chevron.left") { model.go(to: model.currentPage - 1, remember: false) }
                            .disabled(model.currentPage == 0)
                        Button("Next chapter", systemImage: "chevron.right") { model.go(to: model.currentPage + 1, remember: false) }
                            .disabled(model.currentPage >= model.source.pageCount - 1)
                    }
                }
                if model.reflowable != nil {
                    if !(model.source is WebArchiveSource) {
                        Picker("Layout", selection: $layout) {
                            ForEach(ReflowLayout.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                        }
                    }
                    Section("Text size") {
                        Button("Larger", systemImage: "plus.magnifyingglass") { fontScale = min(2.0, fontScale + 0.1) }
                        Button("Smaller", systemImage: "minus.magnifyingglass") { fontScale = max(0.7, fontScale - 0.1) }
                    }
                } else {
                    Picker("Page turning", selection: $turning) {
                        ForEach(PageTurning.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    Section("Text recognition") {
                        Button("Recognize text on this page", systemImage: "doc.text.viewfinder") { model.recognizeCurrentPage() }
                        Button("Recognize whole document", systemImage: "doc.on.doc") { model.recognizeDocument() }
                        if model.pdfDocument != nil {
                            Toggle(isOn: $model.imageMode) { Label("Live Text mode (for scans)", systemImage: "camera.viewfinder") }
                        }
                    }
                }
            }
        }
    }

    /// Web pages are read as one continuous page; books follow the user's layout choice.
    private var effectiveLayout: ReflowLayout {
        model.source is WebArchiveSource ? .scroll : layout
    }

    private var pageLabel: String {
        guard model.reflowable != nil else { return "\(model.currentPage + 1) / \(model.source.pageCount)" }
        return "\(model.globalPage) / \(model.pagesAreExact ? "" : "≈")\(model.totalPages)"
    }

    /// Spoken (and used by UI tests): "Chapter 2 of 9, page 34 of 480".
    private var pageAccessibilityLabel: String {
        guard model.reflowable != nil else { return "Page \(model.currentPage + 1) of \(model.source.pageCount)" }
        return "Chapter \(model.currentPage + 1) of \(model.source.pageCount), page \(model.globalPage) of \(model.totalPages)"
    }
}

private struct HighlightsList: View {
    let model: ReaderModel
    let onSelect: (Highlight) -> Void
    let onSelectBookmark: (Bookmark) -> Void
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $tab) {
                    Text("Highlights").tag(0)
                    Text("Bookmarks").tag(1)
                }
                .pickerStyle(.segmented).padding([.horizontal, .top])
                if tab == 0 { highlightList } else { bookmarkList }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if !model.highlightLocationDescription.isEmpty {
                    Text("Saved as text in \(model.highlightLocationDescription)")
                        .font(.footnote).foregroundStyle(.secondary).padding(8)
                }
            }
        }
    }

    @ViewBuilder
    private var bookmarkList: some View {
        if model.bookmarks.isEmpty {
            ContentUnavailableView("No bookmarks yet", systemImage: "bookmark",
                                   description: Text("Tap the bookmark button to mark the current page."))
        } else {
            List {
                ForEach(model.bookmarks) { bookmark in
                    Button { onSelectBookmark(bookmark) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("p. \(model.page(of: bookmark))").font(.headline)
                                Text(bookmark.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let doomed = offsets.map { model.bookmarks[$0] }
                    Task { for b in doomed { await model.removeBookmark(b) } }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var highlightList: some View {
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

/// Play/pause, stop, speed and voice while reading aloud.
private struct ReadAloudBar: View {
    @Bindable var readAloud: ReadAloud

    var body: some View {
        HStack(spacing: 6) {
            Button(readAloud.state == .playing ? "Pause" : "Play",
                   systemImage: readAloud.state == .playing ? "pause.fill" : "play.fill") { readAloud.toggle() }
                .labelStyle(.iconOnly).font(.title3).frame(width: 40, height: 36)
            Button("Stop", systemImage: "stop.fill") { readAloud.stop() }
                .labelStyle(.iconOnly).frame(width: 36, height: 36)
            Divider().frame(height: 22)
            Menu {
                Picker("Speed", selection: $readAloud.speed) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
            } label: {
                Text(String(format: "%g×", readAloud.speed)).monospacedDigit().frame(minWidth: 44, minHeight: 36)
            }
            Menu {
                Picker("Voice", selection: $readAloud.voiceID) {
                    Text("Automatic (by language)").tag(String?.none)
                    ForEach(readAloud.voicesForCurrentLanguage, id: \.identifier) { voice in
                        Text("\(voice.name)\(voice.quality == .premium ? " · Premium" : voice.quality == .enhanced ? " · Enhanced" : "")")
                            .tag(Optional(voice.identifier))
                    }
                }
            } label: {
                Label("Voice", systemImage: "person.wave.2").labelStyle(.iconOnly).frame(width: 40, height: 36)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .glassEffect(in: .capsule)
    }
}

private struct BackPill: View {
    let label: String
    let depth: Int
    let onBack: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onBack) {
                Label(depth > 1 ? "Back to \(label) (\(depth))" : "Back to \(label)", systemImage: "arrow.uturn.backward")
                    .font(.callout.weight(.medium))
                    .padding(.leading, 14).padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            Button("Forget", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly).font(.caption).foregroundStyle(.secondary)
                .padding(.trailing, 12).padding(.vertical, 9)
                .buttonStyle(.plain)
        }
        .glassEffect(in: .capsule)
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
    @State private var value: Double = 1
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var total: Int { max(1, model.totalPages) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Page \(Int(value)) of \(model.pagesAreExact || model.reflowable == nil ? "" : "≈")\(total)")
                .font(.headline).monospacedDigit()
            if let chapter = chapterTitle(forPage: Int(value)) {
                Text(chapter).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Slider(value: $value, in: 1...Double(max(2, total)), step: 1) { editing in
                if !editing { go(to: Int(value)) }
            }
            HStack {
                TextField("Go to page", text: $typed)
                    .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(goTyped)
                Button("Go", action: goTyped).buttonStyle(.borderedProminent)
                    .disabled(Int(typed) == nil)
            }
            if model.reflowable != nil && !model.pagesAreExact {
                Text("Counting pages… numbers marked ≈ are estimates.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { value = Double(model.reflowable == nil ? model.currentPage + 1 : model.globalPage) }
    }

    private func chapterTitle(forPage page: Int) -> String? {
        guard let book = model.reflowable, book.pageCount > 1 else { return nil }
        let chapter = model.location(ofGlobalPage: page).chapter
        return book.chapterTitles.indices.contains(chapter) ? book.chapterTitles[chapter] : nil
    }

    private func go(to page: Int) {
        let page = min(max(1, page), total)
        if model.reflowable == nil { model.go(to: page - 1) } else { model.go(toGlobalPage: page) }
    }

    private func goTyped() {
        guard let page = Int(typed) else { return }
        value = Double(min(max(1, page), total))
        go(to: page)
        fieldFocused = false
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
