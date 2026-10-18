import ReaderCore
import SwiftUI
import Translation

struct ReaderScreen: View {
    let book: Book
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ReaderModel?
    @State private var openError: String?
    /// PDF/DjVu shown as reflowable text (remembered per book).
    @State private var asText: Bool?

    var body: some View {
        Group {
            if let model {
                ReaderContent(model: model) { on in
                    ReaderModel.setViewsAsText(on, for: book)
                    asText = on
                }
            } else if let openError {
                ContentUnavailableView("Can't open \(book.title)", systemImage: "exclamationmark.triangle", description: Text(openError))
            } else {
                ProgressView()
            }
        }
        .task(id: "\(book.url.path)|\(asText ?? ReaderModel.viewsAsText(book))") {
            do {
                model?.stopTextConversion()
                model = try await ReaderModel.load(book: book, startPage: library.lastPage(book),
                                                   startProgress: library.lastProgress(book),
                                                   ocrLanguages: settings.ocrLanguages,
                                                   highlightStore: HighlightStore.shared,
                                                   asText: asText ?? ReaderModel.viewsAsText(book))
                model?.convertToText()
            } catch {
                openError = error.localizedDescription
            }
        }
        .task(id: model == nil) {
            // Arrived through a highlight or passage link: show it once the viewer has laid out.
            guard let model else { return }
            if let pending = library.pendingQuote {
                library.pendingQuote = nil
                try? await Task.sleep(for: .seconds(1))
                await model.reveal(pending.quote, page: pending.page)
            }
            guard let id = library.pendingHighlight,
                  let highlight = model.highlights.first(where: { $0.id == id }) else { return }
            library.pendingHighlight = nil
            try? await Task.sleep(for: .seconds(1))
            model.reveal(highlight)
        }
        .onChange(of: model?.currentPage) { _, page in
            if let page { library.setLastPage(page, for: book); model?.publishPosition() }
        }
        .onChange(of: model?.pageProgress) { _, progress in
            if let progress { library.setLastProgress(progress, for: book); model?.publishPosition() }
        }
        .task(id: model == nil) {
            // Another device may have read on: offer its position once the viewer is up.
            guard let model else { return }
            try? await Task.sleep(for: .seconds(1))
            await model.checkRemotePosition(localSavedAt: library.lastPositionDate(book))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model?.pausePace() }
            guard phase == .active, let model else { return }
            Task { await model.checkRemotePosition(localSavedAt: library.lastPositionDate(book)) }
        }
        .onChange(of: settings.ocrLanguages) { _, languages in
            guard let text = model?.text else { return }
            Task { await text.setLanguages(languages) }
        }
    }
}

private struct ReaderContent: View {
    @Bindable var model: ReaderModel
    /// Switch a PDF/DjVu between its pages and the converted text.
    var onViewAsText: (Bool) -> Void = { _ in }
    @Environment(SettingsStore.self) private var settings
    @Environment(DeviceTransfers.self) private var transfers
    @State private var showAssistant = false
    @State private var showOutline = false
    @State private var showPagePicker = false
    @State private var dictionaryTerm: DictionaryTerm?
    @State private var showTranslation = false
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("reflowLayout") private var layout: ReflowLayout = .paged
    @AppStorage("pageTurning") private var turning: PageTurning = .horizontal
    @State private var showHighlights = false
    @State private var confirmRemovePageNote = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(ImprovementNoteRequest.self) private var noteRequest

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
                if let progress = model.textConversion {
                    OCRProgressPill(progress: progress, title: "Converting to text") { model.stopTextConversion() }
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
                        onHighlight: { color in Task { await model.addHighlight(color: color) } },
                        onNote: { Task { await model.annotateSelection() } },
                        onThroughline: ThroughlineSender.isAvailable ? { ThroughlineSender.send(model) } : nil)
                }
            }
            .padding(.bottom, 20)
            .padding(.horizontal)
            .animation(.snappy, value: model.selection.isEmpty)
        }
        .overlay(alignment: .top) {
            // Centred under the title: near the trailing toolbar buttons their touch areas swallow taps.
            VStack(spacing: 8) {
                if let back = model.backStack.last {
                    BackPill(label: back.label, depth: model.backStack.count,
                             onBack: { model.goBack() }, onDismiss: { model.clearBackStack() })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let remote = model.remotePosition {
                    RemotePositionPill(position: remote, current: model.currentPosition.label,
                                       onGo: { model.acceptRemotePosition() }, onStay: { model.declineRemotePosition() })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let mark = model.currentBookmark, mark.hasAnnotation {
                    PageNotePill(bookmark: mark) { model.annotating = .bookmark(mark) }
                        .padding(.horizontal, 60)   // long notes truncate instead of spanning the page
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        }
        .animation(.snappy, value: model.backStack.count)
        .animation(.snappy, value: model.remotePosition)
        .onChange(of: model.readingPageNumber) {
            model.noteReadingPosition()
            model.notePageTurn()
        }
        .onChange(of: transfers.status) { _, status in if let status { model.statusMessage = status } }
        .onDisappear { model.readAloud.stop() }
        .navigationTitle(model.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if compact { compactToolbar } else { toolbar }
        }
        .sheet(isPresented: compactOnly($showOutline)) { bookIndex(.contents) }
        .sheet(isPresented: compactOnly($showPagePicker)) {
            PagePicker(model: model, onDone: { showPagePicker = false }).padding().presentationDetents([.height(260)])
        }
        .sheet(isPresented: compactOnly($showHighlights)) {
            bookIndex(.highlights)
        }
        .inspector(isPresented: $showAssistant) {
            AssistantPanel(model: model, onClose: { showAssistant = false })
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
            Button(highlight.hasAnnotation ? "Edit Note" : "Add Note") { model.annotating = .highlight(highlight) }
            Button("Ask the assistant about it") {
                model.selection = highlight.text
                showAssistant = true
                model.ask("", action: .explain, settings: settings)
            }
            if ThroughlineSender.isAvailable {
                Button("Send to Throughline") { ThroughlineSender.send(model, highlight: highlight) }
            }
            Button("Remove highlight", role: .destructive) { Task { await model.removeHighlight(highlight) } }
        } message: { highlight in
            Text("“\(highlight.text.prefix(140))”")
        }
        .sheet(item: $model.annotating) { target in
            AnnotationEditor(model: model, target: target)
        }
        .confirmationDialog("This page has a note", isPresented: $confirmRemovePageNote) {
            Button("Remove Bookmark and Note", role: .destructive) { Task { await model.toggleBookmark() } }
        } message: {
            Text("The page note is kept with the bookmark, so removing the bookmark deletes the note too.")
        }
    }

    @ViewBuilder
    private var viewer: some View {
        if let book = model.reflowable {
            ReflowableView(model: model, book: book, layout: effectiveLayout, fontScale: fontScale)
                .id(effectiveLayout)
                // Pinch to change the text size (applied when the pinch ends, so the text reflows once).
                .simultaneousGesture(MagnifyGesture().onEnded { value in
                    fontScale = TextSizeControls.clamp(fontScale * value.magnification)
                    model.statusMessage = "Text size \(Int((fontScale * 100).rounded()))%"
                })
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
            Button("Contents", systemImage: "list.bullet") { showOutline = true }
                .popover(isPresented: $showOutline) { bookIndex(.contents).frame(minWidth: 360, minHeight: 460) }
            if model.reflowable != nil && model.source.pageCount > 1 {
                Button("Previous chapter", systemImage: "chevron.left") { model.go(to: model.currentPage - 1, remember: false) }
                    .disabled(model.currentPage == 0)
            }
            Button(pageLabel) { showPagePicker = true }
                .monospacedDigit()
                .accessibilityLabel(pageAccessibilityLabel)
                .popover(isPresented: $showPagePicker) {
                    PagePicker(model: model, onDone: { showPagePicker = false }).padding().frame(width: 320)
                }
            if model.reflowable != nil && model.source.pageCount > 1 {
                Button("Next chapter", systemImage: "chevron.right") { model.go(to: model.currentPage + 1, remember: false) }
                    .disabled(model.currentPage >= model.source.pageCount - 1)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.reflowable != nil {
                Menu("Text Size & Layout", systemImage: "textformat.size") {
                    TextSizeControls(fontScale: $fontScale)
                    if model.isViewingAsText {
                        Button("View Original Pages", systemImage: "doc.richtext") { onViewAsText(false) }
                    }
                    if !(model.source is WebArchiveSource) {
                        Picker("Layout", selection: $layout) {
                            ForEach(ReflowLayout.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                        }
                    }
                }
            } else {
                Menu("Page layout", systemImage: turning.systemImage) {
                    Picker("Page turning", selection: $turning) {
                        ForEach(PageTurning.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                }
                Menu("Text", systemImage: "text.viewfinder") {
                    if model.canViewAsText {
                        Button("View as Text", systemImage: "text.justify.left") { onViewAsText(true) }
                        Divider()
                    }
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
                bookmarkTapped()
            }
            Button("Page Note", systemImage: pageNoteIcon) { Task { await model.annotatePage() } }
            Button(model.readAloud.state == .idle ? "Read aloud" : "Stop reading aloud",
                   systemImage: model.readAloud.state == .idle ? "speaker.wave.2" : "speaker.slash") {
                if model.readAloud.state == .idle { model.readAloud.start(model) } else { model.readAloud.stop() }
            }
            Button("Highlights", systemImage: "highlighter") { showHighlights = true }
                .popover(isPresented: $showHighlights) { bookIndex(.highlights).frame(minWidth: 360, minHeight: 460) }
            SendToMenu(book: model.book.url)          // send this book to another device, while reading
            ReadingLinkActions(model: model)
            Button("Assistant", systemImage: "sparkles") { showAssistant.toggle() }
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Suggest an Improvement…", systemImage: "lightbulb") { noteRequest.start(context: noteContext, file: noteFile) }
            }
        }
    }

    /// Contents, bookmarks and highlights in one panel (like Apple Books), opened on `tab`.
    private func bookIndex(_ tab: HighlightsList.Tab) -> some View {
        HighlightsList(model: model, initialTab: tab, onSelectPage: { page in
            showOutline = false
            showHighlights = false
            model.go(to: page)
        }, onSelect: { highlight in
            showOutline = false
            showHighlights = false
            model.reveal(highlight)
        }, onSelectBookmark: { bookmark in
            showOutline = false
            showHighlights = false
            model.open(bookmark)
        }, onAnnotate: annotateFromList)
    }

    /// The list is a popover/sheet; let it close before the note editor sheet opens.
    private func annotateFromList(_ target: AnnotationTarget) {
        showOutline = false
        showHighlights = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            model.annotating = target
        }
    }

    private var pageNoteIcon: String {
        model.currentBookmark?.hasAnnotation == true ? "note.text" : "note.text.badge.plus"
    }

    /// Removing the bookmark of a page with a note would delete the note: ask first.
    private func bookmarkTapped() {
        if model.currentBookmark?.hasAnnotation == true {
            confirmRemovePageNote = true
        } else {
            Task { await model.toggleBookmark() }
        }
    }

    /// The open book's path in the library ("Physics/Thermodynamics.djvu"), so a note names the exact file.
    private var noteFile: String {
        let path = model.book.url.standardizedFileURL.path
        let root = LibraryStore.rootURL.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : model.book.url.lastPathComponent
    }

    /// Where an improvement note was written: book, format, page and view mode.
    private var noteContext: String {
        let mode = model.reflowable != nil ? effectiveLayout.title : (model.imageMode ? "Live Text" : turning.title)
        return "\(model.book.title) (\(model.book.format)), \(model.currentPosition.label), \(mode)"
    }

    /// On iPhone these panels are sheets on the root view (the iPad popovers hang off toolbar buttons).
    private func compactOnly(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { compact && binding.wrappedValue }, set: { binding.wrappedValue = $0 })
    }

    @ToolbarContentBuilder
    private var compactToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("Contents", systemImage: "list.bullet") { showOutline = true }
            Button(pageLabel) { showPagePicker = true }
                .monospacedDigit()
                .accessibilityLabel(pageAccessibilityLabel)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(model.currentBookmark == nil ? "Bookmark this page" : "Remove bookmark",
                   systemImage: model.currentBookmark == nil ? "bookmark" : "bookmark.fill") {
                bookmarkTapped()
            }
            Button("Assistant", systemImage: "sparkles") { showAssistant.toggle() }
            Menu("More", systemImage: "ellipsis.circle") {
                Button(model.readAloud.state == .idle ? "Read aloud" : "Stop reading aloud",
                       systemImage: model.readAloud.state == .idle ? "speaker.wave.2" : "speaker.slash") {
                    if model.readAloud.state == .idle { model.readAloud.start(model) } else { model.readAloud.stop() }
                }
                Button("Page Note", systemImage: pageNoteIcon) { Task { await model.annotatePage() } }
                Button("Highlights & Notes", systemImage: "highlighter") { showHighlights = true }
                SendToMenu(book: model.book.url)
                ReadingLinkActions(model: model)
                Button("Suggest an Improvement…", systemImage: "lightbulb") { noteRequest.start(context: noteContext, file: noteFile) }
                if model.reflowable != nil && model.source.pageCount > 1 {
                    Section {
                        Button("Previous chapter", systemImage: "chevron.left") { model.go(to: model.currentPage - 1, remember: false) }
                            .disabled(model.currentPage == 0)
                        Button("Next chapter", systemImage: "chevron.right") { model.go(to: model.currentPage + 1, remember: false) }
                            .disabled(model.currentPage >= model.source.pageCount - 1)
                    }
                }
                if model.reflowable != nil {
                    if model.isViewingAsText {
                        Button("View Original Pages", systemImage: "doc.richtext") { onViewAsText(false) }
                    }
                    if !(model.source is WebArchiveSource) {
                        Picker("Layout", selection: $layout) {
                            ForEach(ReflowLayout.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                        }
                    }
                    TextSizeControls(fontScale: $fontScale)
                } else {
                    Picker("Page turning", selection: $turning) {
                        ForEach(PageTurning.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    Section("Text recognition") {
                        if model.canViewAsText {
                            Button("View as Text", systemImage: "text.justify.left") { onViewAsText(true) }
                        }
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
        let pages = model.reflowable == nil ? "\(model.currentPage + 1) / \(model.source.pageCount)"
            : "\(model.globalPage) / \(model.pagesAreExact ? "" : "≈")\(model.totalPages)"
        // Time left at your pace, where there's room (not on iPhone).
        guard !compact, let left = model.timeLeftText else { return pages }
        return pages + " · " + left
    }

    /// Spoken (and used by UI tests): "Chapter 2 of 9, page 34 of 480".
    private var pageAccessibilityLabel: String {
        let left = model.timeLeftText.map { ", \($0)" } ?? ""
        guard model.reflowable != nil else { return "Page \(model.currentPage + 1) of \(model.source.pageCount)\(left)" }
        return "Chapter \(model.currentPage + 1) of \(model.source.pageCount), page \(model.globalPage) of \(model.totalPages)\(left)"
    }
}

struct HighlightsList: View {
    enum Tab: Hashable { case contents, bookmarks, highlights }

    let model: ReaderModel
    let onSelectPage: (Int) -> Void
    let onSelect: (Highlight) -> Void
    let onSelectBookmark: (Bookmark) -> Void
    let onAnnotate: (AnnotationTarget) -> Void
    @State private var tab: Tab

    init(model: ReaderModel, initialTab: Tab, onSelectPage: @escaping (Int) -> Void, onSelect: @escaping (Highlight) -> Void,
         onSelectBookmark: @escaping (Bookmark) -> Void, onAnnotate: @escaping (AnnotationTarget) -> Void) {
        self.model = model
        self.onSelectPage = onSelectPage
        self.onSelect = onSelect
        self.onSelectBookmark = onSelectBookmark
        self.onAnnotate = onAnnotate
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $tab) {
                    Text("Contents").tag(Tab.contents)
                    Text("Bookmarks").tag(Tab.bookmarks)
                    Text("Highlights").tag(Tab.highlights)
                }
                .pickerStyle(.segmented).padding([.horizontal, .top])
                switch tab {
                case .contents: contentsList
                case .bookmarks: bookmarkList
                case .highlights: highlightList
                }
            }
            .navigationTitle(model.book.title)
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
    private var contentsList: some View {
        if model.source.outline.isEmpty {
            ContentUnavailableView("No table of contents", systemImage: "list.bullet",
                                   description: Text("This book doesn't include one. Use the page number at the top to jump to a page."))
        } else {
            OutlineView(items: model.source.outline, onSelect: onSelectPage)
        }
    }

    @ViewBuilder
    private var bookmarkList: some View {
        if model.bookmarks.isEmpty {
            ContentUnavailableView("No bookmarks yet", systemImage: "bookmark",
                                   description: Text("Tap the bookmark button to mark the current page, or Page Note to write on it."))
        } else {
            List {
                ForEach(model.bookmarks) { bookmark in
                    Button { onSelectBookmark(bookmark) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: bookmark.hasAnnotation ? "note.text" : "bookmark.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("p. \(model.page(of: bookmark))").font(.headline)
                                Text(bookmark.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                AnnotationSummary(item: bookmark)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button(bookmark.hasAnnotation ? "Edit Note" : "Add Note", systemImage: "note.text") {
                            onAnnotate(.bookmark(bookmark))
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button(bookmark.hasAnnotation ? "Edit Note" : "Add Note", systemImage: "note.text") {
                            onAnnotate(.bookmark(bookmark))
                        }
                    }
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
                                        AnnotationSummary(item: highlight)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .leading) {
                                Button(highlight.hasAnnotation ? "Edit Note" : "Add Note", systemImage: "note.text") {
                                    onAnnotate(.highlight(highlight))
                                }
                                .tint(.orange)
                            }
                            .contextMenu {
                                Button(highlight.hasAnnotation ? "Edit Note" : "Add Note", systemImage: "note.text") {
                                    onAnnotate(.highlight(highlight))
                                }
                            }
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

/// Share a link to this page (title + deep link, so Throughline's share extension can capture it) and Send to Throughline.
private struct ReadingLinkActions: View {
    let model: ReaderModel

    var body: some View {
        if let link = model.readingLink() {
            ShareLink(item: link.url, subject: Text(link.title), message: link.text.isEmpty ? nil : Text(link.text),
                      preview: SharePreview(link.title)) {
                Label("Share Link to Page", systemImage: "link")
            }
            if ThroughlineSender.isAvailable {
                Button("Send to Throughline", systemImage: "checklist") { ThroughlineSender.send(model) }
            }
        }
    }
}

/// Smaller / size (tap to reset) / Larger, side by side at the top of the menu.
private struct TextSizeControls: View {
    @Binding var fontScale: Double
    static func clamp(_ scale: Double) -> Double { min(3.0, max(0.6, (scale * 20).rounded() / 20)) }

    var body: some View {
        ControlGroup("Text Size") {
            Button("Smaller Text", systemImage: "textformat.size.smaller") { fontScale = Self.clamp(fontScale - 0.1) }
            // Shows the size; tapping it goes back to 100%.
            Button("\(Int((fontScale * 100).rounded()))%") { fontScale = 1.0 }
            Button("Larger Text", systemImage: "textformat.size.larger") { fontScale = Self.clamp(fontScale + 0.1) }
        }
        .controlGroupStyle(.compactMenu)
    }
}

private struct SelectionBar: View {
    let selection: String
    let onAction: (QuickAction) -> Void
    let onAsk: () -> Void
    let onDictionary: () -> Void
    let onTranslate: () -> Void
    let onHighlight: (Highlight.Color) -> Void
    let onNote: () -> Void
    /// Nil when Throughline isn't installed.
    let onThroughline: (() -> Void)?

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
            // Always labelled: it's the main action on a selection and an icon alone is easy to miss.
            bar("Highlight", "highlighter", true) { onHighlight(.yellow) }
                .contextMenu {
                    ForEach(Highlight.Color.allCases, id: \.self) { color in
                        Button(color.rawValue.capitalized) { onHighlight(color) }
                    }
                }
            bar("Note", "note.text.badge.plus", showTitles, action: onNote)
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
            if let onThroughline {
                bar("Send to Throughline", "checklist", showTitles, action: onThroughline)
            }
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
                .accessibilityValue(readAloud.nowReading)
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
                .labelStyle(.iconOnly).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
                .padding(.trailing, 4)
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
            // A new message cancels this wait — then it must not close the new one.
            guard (try? await Task.sleep(for: .seconds(4))) != nil else { return }
            onClose()
        }
    }
}

private struct OCRProgressPill: View {
    let progress: Double
    var title = "Recognizing"
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: progress).frame(width: 160)
            Text("\(title) \(Int(progress * 100))%").font(.callout).monospacedDigit()
            Button("Stop", action: onCancel).buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(in: .capsule)
    }
}

private struct PagePicker: View {
    let model: ReaderModel
    /// Close the picker: after typing a page number the reader wants the page, not the picker. (Left
    /// open, the next touch on the page only dismissed it — a long-press then selected nothing.)
    var onDone: () -> Void = {}
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
            if let left = model.timeLeft {
                Label("About \(ReadingPace.describe(left)) to finish, at your pace (\(model.paceText ?? ""))", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Time to finish appears after a few pages.", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
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
        onDone()
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

/// A note's text (first lines) and a drawing marker, under a highlight or page in lists.
struct AnnotationSummary: View {
    let item: any Annotatable

    var body: some View {
        if item.hasAnnotation {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if item.drawingID != nil {
                    Image(systemName: "scribble.variable").accessibilityLabel("Drawing")
                }
                if let note = item.note, item.hasNote {
                    Text(note).lineLimit(3)
                } else {
                    Text("Drawing")
                }
            }
            .font(.callout)
            .foregroundStyle(.orange)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Shown at the top of a page that has a note; tap to read or edit it.
private struct PageNotePill: View {
    let bookmark: Bookmark
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: bookmark.drawingID != nil && !bookmark.hasNote ? "scribble.variable" : "note.text")
                Text(bookmark.note.flatMap { bookmark.hasNote ? $0 : nil } ?? "Drawing")
                    .lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(.capsule)   // a plain button only takes taps where something is drawn
        }
        .buttonStyle(.plain)
        .glassEffect(in: .capsule)
        .accessibilityLabel("Page note")
        .accessibilityIdentifier("pageNote.pill")
    }
}
