import ReaderCore
import SwiftUI

/// One book window: contents/bookmarks/highlights in the sidebar, the page in the middle, the assistant
/// in an inspector on the right.
struct MacReaderView: View {
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
                MacReaderContent(model: model) { on in
                    ReaderModel.setViewsAsText(on, for: book)
                    asText = on
                }
            } else if let openError {
                ContentUnavailableView("Can't Open This Book", systemImage: "exclamationmark.triangle", description: Text(openError))
            } else {
                ProgressView("Opening…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(book.title)
        .navigationSubtitle(model.map { m in
            ["\(m.currentPosition.label)", book.format, m.timeLeftText,
             m.textConversion.map { "Converting to text \(Int($0 * 100))%" }].compactMap { $0 }.joined(separator: " · ")
        } ?? book.format)
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
            guard let model else { return }
            try? await Task.sleep(for: .seconds(1))
            if let id = library.pendingHighlight, let highlight = model.highlights.first(where: { $0.id == id }) {
                library.pendingHighlight = nil
                model.reveal(highlight)
            }
            if let pending = library.pendingQuote {
                library.pendingQuote = nil
                await model.reveal(pending.quote, page: pending.page)
            }
            await model.checkRemotePosition(localSavedAt: library.lastPositionDate(book))
        }
        .onChange(of: model?.currentPage) { _, page in
            if let page { library.setLastPage(page, for: book); model?.publishPosition() }
        }
        .onChange(of: model?.pageProgress) { _, progress in
            if let progress { library.setLastProgress(progress, for: book); model?.publishPosition() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model?.pausePace() }
            guard phase == .active, let model else { return }
            Task { await model.checkRemotePosition(localSavedAt: library.lastPositionDate(book)) }
        }
        .onDisappear { model?.readAloud.stop() }
    }
}

struct MacReaderContent: View {
    @Bindable var model: ReaderModel
    /// Switch a PDF/DjVu between its pages and the converted text.
    var onViewAsText: (Bool) -> Void = { _ in }
    @Environment(SettingsStore.self) private var settings
    @Environment(DeviceTransfers.self) private var transfers
    @State private var showAssistant = false
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var indexTab: MacBookIndex.Tab = .contents
    @State private var showGoTo = false
    @AppStorage("mac.reflowLayout") private var layout: ReflowLayout = .scroll
    @AppStorage("mac.fontScale") private var fontScale = 1.0
    @AppStorage("mac.twoPages") private var twoPages = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MacBookIndex(model: model, tab: $indexTab)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            viewer
                .overlay(alignment: .top) { topPills }
                .overlay(alignment: .bottom) {
                    if model.readAloud.state != .idle { MacReadAloudBar(readAloud: model.readAloud).padding(.bottom, 16) }
                }
                .animation(.snappy, value: model.remotePosition)
                .animation(.snappy, value: model.backStack.count)
        }
        .inspector(isPresented: $showAssistant) {
            AssistantPanel(model: model, onClose: { showAssistant = false })
                .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
        }
        .toolbar { toolbar }
        .focusedSceneValue(\.reader, MacReaderActions(
            model: model,
            toggleAssistant: { showAssistant.toggle() },
            toggleSidebar: { columns = columns == .detailOnly ? .all : .detailOnly },
            goToPage: { showGoTo = true }))
        .sheet(item: $model.annotating) { target in
            MacAnnotationEditor(model: model, target: target)
        }
        .confirmationDialog("Highlight", isPresented: Binding(get: { model.tappedHighlight != nil },
                                                              set: { if !$0 { model.tappedHighlight = nil } }),
                            presenting: model.tappedHighlight) { highlight in
            Button(highlight.hasAnnotation ? "Edit Note…" : "Add Note…") { model.annotating = .highlight(highlight) }
            ForEach(Highlight.Color.allCases.filter { $0 != highlight.color }, id: \.self) { color in
                Button("Make \(color.rawValue.capitalized)") { Task { await model.recolor(highlight, to: color) } }
            }
            Button("Ask the Assistant") {
                model.selection = highlight.text
                showAssistant = true
                model.ask("", action: .explain, settings: settings)
            }
            if ThroughlineSender.isAvailable {
                Button("Send to Throughline") { ThroughlineSender.send(model, highlight: highlight) }
            }
            Button("Remove Highlight", role: .destructive) { Task { await model.removeHighlight(highlight) } }
        } message: { highlight in
            Text("“\(highlight.text.prefix(140))”")
        }
        .sheet(isPresented: $showGoTo) { MacGoToPage(model: model) }
        .onChange(of: transfers.status) { _, status in if let status { model.statusMessage = status } }
        .overlay(alignment: .bottom) {
            if let message = model.statusMessage {
                Text(message).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(in: .capsule).padding(.bottom, 60)
                    .task(id: message) { if (try? await Task.sleep(for: .seconds(4))) != nil { model.statusMessage = nil } }
            }
        }
    }

    // MARK: Viewer

    @ViewBuilder
    private var viewer: some View {
        if let book = model.reflowable {
            let effective: ReflowLayout = model.source is WebArchiveSource ? .scroll : layout
            ReflowableView(model: model, book: book, layout: effective, fontScale: fontScale,
                           contextMenu: { menu, link in extend(menu, link: link) })
                .id(effective)
        } else if model.imageMode || model.pdfDocument == nil {
            MacImagePagesView(model: model, contextMenu: { menu in extend(menu, link: nil) })
        } else {
            PDFKitView(model: model, twoPages: twoPages, contextMenu: { menu, link in extend(menu, link: link?.0) })
        }
    }

    @ViewBuilder
    private var topPills: some View {
        VStack(spacing: 8) {
            if let remote = model.remotePosition {
                RemotePositionPill(position: remote, current: model.currentPosition.label,
                                   onGo: { model.acceptRemotePosition() }, onStay: { model.declineRemotePosition() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let back = model.backStack.last {
                HStack(spacing: 6) {
                    Button("Back to \(back.label)", systemImage: "arrow.uturn.backward") { model.goBack() }
                        .buttonStyle(.plain)
                    Button("Forget", systemImage: "xmark") { model.clearBackStack() }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glassEffect(in: .capsule)
            }
            if let mark = model.currentBookmark, mark.hasAnnotation {
                Button {
                    model.annotating = .bookmark(mark)
                } label: {
                    Label(mark.note.flatMap { mark.hasNote ? $0 : nil } ?? "Drawing", systemImage: "note.text")
                        .lineLimit(1).font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(in: .capsule)
            }
        }
        .padding(.top, 10)
        .onChange(of: model.readingPageNumber) {
            model.noteReadingPosition()
            model.notePageTurn()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Previous", systemImage: "chevron.left") { model.pageBackward() }
                .help("Previous page (⌘←)")
            Button(pageLabel) { showGoTo = true }
                .monospacedDigit()
                .help("Go to page… (⌥⌘G)")
            Button("Next", systemImage: "chevron.right") { model.pageForward() }
                .help("Next page (⌘→)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.reflowable != nil {
                Menu("Text", systemImage: "textformat.size") {
                    if !(model.source is WebArchiveSource) {
                        Picker("Layout", selection: $layout) {
                            Text("Scroll").tag(ReflowLayout.scroll)
                            Text("Pages").tag(ReflowLayout.paged)
                        }
                    }
                    Button("Bigger") { fontScale = min(2.0, fontScale + 0.1) }.keyboardShortcut("+")
                    Button("Smaller") { fontScale = max(0.7, fontScale - 0.1) }.keyboardShortcut("-")
                    Button("Actual Size") { fontScale = 1.0 }.keyboardShortcut("0")
                    if model.isViewingAsText {
                        Divider()
                        Button("View Original Pages") { onViewAsText(false) }
                    }
                }
            } else if model.pdfDocument != nil {
                Menu("View", systemImage: "rectangle.split.2x1") {
                    Button("View as Text") { onViewAsText(true) }
                    Divider()
                    Toggle("Two Pages", isOn: $twoPages)
                    Toggle("Live Text Mode (for scans)", isOn: $model.imageMode)
                    Divider()
                    Button("Recognize Text on This Page") { model.recognizeCurrentPage() }
                    Button("Recognize Whole Document") { model.recognizeDocument() }
                }
            } else {
                Menu("Text", systemImage: "text.viewfinder") {
                    if model.canViewAsText { Button("View as Text") { onViewAsText(true) }; Divider() }
                    Button("Recognize Text on This Page") { model.recognizeCurrentPage() }
                    Button("Recognize Whole Document") { model.recognizeDocument() }
                }
            }
            Menu {
                ForEach(Highlight.Color.allCases, id: \.self) { color in
                    Button(color.rawValue.capitalized) { Task { await model.addHighlight(color: color) } }
                }
                Divider()
                Button("Note on Selection…") { Task { await model.annotateSelection() } }
            } label: {
                Label("Highlight", systemImage: "highlighter")
            } primaryAction: {
                Task { await model.addHighlight() }
            }
            .disabled(model.selection.isEmpty)
            .help("Highlight the selection (⌃⌘H)")
            Button(model.currentBookmark == nil ? "Bookmark" : "Remove Bookmark",
                   systemImage: model.currentBookmark == nil ? "bookmark" : "bookmark.fill") {
                Task { await model.toggleBookmark() }
            }
            .help("Bookmark this page (⌘D)")
            Button("Page Note", systemImage: model.currentBookmark?.hasAnnotation == true ? "note.text" : "note.text.badge.plus") {
                Task { await model.annotatePage() }
            }
            Button(model.readAloud.state == .idle ? "Read Aloud" : "Stop", systemImage: model.readAloud.state == .idle ? "speaker.wave.2" : "speaker.slash") {
                if model.readAloud.state == .idle { model.readAloud.start(model) } else { model.readAloud.stop() }
            }
            .help("Read aloud from here (⌥⌘R); click a word while reading to continue from it")
            SendToMenu(book: model.book.url)
                .help("Send this book to your iPad, iPhone or another Mac")
            Button("Assistant", systemImage: "sparkles") { showAssistant.toggle() }
                .help("Ask about the page or the selection (⌥⌘A)")
        }
    }

    private var pageLabel: String {
        guard model.reflowable != nil else { return "\(model.currentPage + 1) / \(model.source.pageCount)" }
        return "\(model.globalPage) / \(model.pagesAreExact ? "" : "≈")\(model.totalPages)"
    }

    // MARK: Context menu

    /// The reader's items at the top of the right-click menu (the system's Look Up, Translate, Copy… stay below).
    private func extend(_ menu: NSMenu, link: URL?) {
        var items: [NSMenuItem] = []
        if !model.selection.isEmpty {
            let highlight = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
            highlight.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
            let colors = NSMenu()
            for color in Highlight.Color.allCases {
                colors.addItem(MenuAction(color.rawValue.capitalized) { Task { await model.addHighlight(color: color) } })
            }
            highlight.submenu = colors
            items.append(highlight)
            items.append(MenuAction("Add Note…", symbol: "note.text.badge.plus") { Task { await model.annotateSelection() } })
            let short = model.selection.split(whereSeparator: \.isWhitespace).count <= 3
            items.append(MenuAction(short ? "Define in Context" : "Explain", symbol: short ? "character.book.closed" : "lightbulb") {
                showAssistant = true
                model.ask("", action: short ? .define : .explain, settings: settings)
            })
            items.append(MenuAction("What Does It Mean?", symbol: "questionmark.bubble") {
                showAssistant = true
                model.ask("", action: .meaning, settings: settings)
            })
            items.append(MenuAction("Translate with Assistant", symbol: "translate") {
                showAssistant = true
                model.ask("", action: .translate, settings: settings)
            })
            items.append(MenuAction("Ask the Assistant…", symbol: "sparkles") { showAssistant = true })
        }
        if let link, !link.isFileURL {
            items.append(MenuAction("Add Link to Read Later", symbol: "text.badge.plus") { model.addToReadLater(url: link, title: nil) })
        }
        if let link, ThroughlineSender.isAvailable {
            items.append(MenuAction("Send Link to Throughline", symbol: "checklist") { ThroughlineSender.sendLink(link, title: nil, from: model) })
        }
        guard !items.isEmpty else { return }
        items.append(.separator())
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
    }
}

/// An NSMenuItem that runs a closure.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// "Go to page" sheet.
struct MacGoToPage: View {
    let model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var total: Int { model.reflowable == nil ? model.source.pageCount : max(1, model.totalPages) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Page").font(.headline)
            TextField("Page (1–\(total))", text: $text)
                .onSubmit(go)
                .frame(width: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Go", action: go).keyboardShortcut(.defaultAction).disabled(Int(text) == nil)
            }
        }
        .padding(20)
    }

    private func go() {
        guard let page = Int(text) else { return }
        let target = min(max(1, page), total)
        if model.reflowable == nil { model.go(to: target - 1) } else { model.go(toGlobalPage: target) }
        dismiss()
    }
}

/// Play/pause, stop and speed while reading aloud.
struct MacReadAloudBar: View {
    @Bindable var readAloud: ReadAloud

    var body: some View {
        HStack(spacing: 10) {
            Button(readAloud.state == .playing ? "Pause" : "Play",
                   systemImage: readAloud.state == .playing ? "pause.fill" : "play.fill") { readAloud.toggle() }
                .labelStyle(.iconOnly)
                .accessibilityValue(readAloud.nowReading)
            Button("Stop", systemImage: "stop.fill") { readAloud.stop() }.labelStyle(.iconOnly)
            Picker("Speed", selection: $readAloud.speed) {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
            }
            .pickerStyle(.menu).fixedSize()
            Text("Click a word to read from there").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(in: .capsule)
    }
}
