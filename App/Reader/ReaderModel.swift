import Foundation
import Observation
import PDFKit
import ReaderCore

/// A place to return to after following a link or jumping elsewhere.
struct ReadingPosition: Equatable {
    let page: Int          // page (fixed layout) or chapter (reflowable)
    let progress: Double   // position within a reflowable chapter
    let label: String      // "p. 12"
}

struct SubPage: Equatable {
    let page: Int
    let pages: Int
}

extension HighlightStore {
    /// One store for the app; resolves the iCloud container lazily off the main thread.
    static let shared = HighlightStore(containerIdentifier: "iCloud.com.romadinov.reader")
}

@MainActor @Observable
final class ReaderModel {
    let book: Book
    let source: PageSource
    let text: TextProvider

    var currentPage = 0
    /// Text currently selected in the viewer (PDFKit selection or Live Text selection).
    var selection = "" {
        // The assistant keeps the last selection as the subject of questions: tapping into the question
        // field takes focus from the book and clears the on-page selection, but the question is still about it.
        didSet { if !selection.isEmpty { questionSelection = selection } }
    }
    /// What the assistant's questions are about, until cleared or replaced by a new selection.
    var questionSelection = ""
    /// PDFs show in PDFKit; DjVu and scanned PDFs use the image viewer with Live Text.
    var imageMode: Bool
    var ocrProgress: Double?
    var statusMessage: String?

    let chat = ChatModel()
    let readAloud = ReadAloud()

    /// Next paragraphs to read aloud as (text, anchor); `restart` = from the current position. Empty = end.
    @ObservationIgnored var speechParagraphs: (@MainActor (_ restart: Bool) async -> [(text: String, anchor: Int)])?
    /// Show the range being spoken (anchor from `speechParagraphs`); nil range clears.
    @ObservationIgnored var speechHighlight: (@MainActor (_ anchor: Int, _ range: NSRange?) -> Void)?
    @ObservationIgnored private var speechPage = 0

    /// Position within the current page/chapter (0…1); reflowable books resume from it.
    var pageProgress: Double = 0
    @ObservationIgnored var startProgress: Double = 0
    /// Page within the current chapter (reflowable books in page layout).
    var subPage: SubPage?

    // Whole-book page numbers for reflowable books: real counts from the Paginator where measured,
    // estimates from text length elsewhere.
    var measuredPages: [Int: Int] = [:]
    var chapterLengths: [Int] = []
    @ObservationIgnored var jumpToPosition: ((Int, Double) -> Void)?

    var chapterPages: [Int] {
        let count = source.pageCount
        let measuredChars = measuredPages.keys.reduce(0) { $0 + (chapterLengths.indices.contains($1) ? chapterLengths[$1] : 0) }
        let measuredTotal = measuredPages.values.reduce(0, +)
        let pagesPerChar = measuredChars > 0 ? Double(measuredTotal) / Double(measuredChars) : 1.0 / 1500
        return (0..<count).map { chapter in
            if let pages = measuredPages[chapter] { return pages }
            let chars = chapterLengths.indices.contains(chapter) ? chapterLengths[chapter] : 1500
            return max(1, Int((Double(chars) * pagesPerChar).rounded()))
        }
    }

    var pagesAreExact: Bool { reflowable != nil && measuredPages.count == source.pageCount }

    /// 1-based page in the whole book.
    var globalPage: Int {
        let pages = chapterPages
        guard pages.indices.contains(currentPage) else { return 1 }
        let before = pages[..<currentPage].reduce(0, +)
        let inChapter = subPage.map { min($0.page, pages[currentPage]) }
            ?? Int((pageProgress * Double(max(0, pages[currentPage] - 1))).rounded()) + 1
        return before + max(1, inChapter)
    }

    var totalPages: Int { reflowable == nil ? source.pageCount : chapterPages.reduce(0, +) }

    /// Chapter and position within it for a 1-based whole-book page.
    func location(ofGlobalPage page: Int) -> (chapter: Int, progress: Double) {
        var remaining = max(1, page)
        for (chapter, pages) in chapterPages.enumerated() {
            if remaining <= pages {
                return (chapter, pages > 1 ? Double(remaining - 1) / Double(pages - 1) : 0)
            }
            remaining -= pages
        }
        return (max(0, source.pageCount - 1), 1)
    }

    func go(toGlobalPage page: Int) {
        guard reflowable != nil else { return go(to: page - 1) }
        pushCurrentPosition()
        let target = location(ofGlobalPage: page)
        if let jumpToPosition {
            jumpToPosition(target.chapter, target.progress)
        } else {
            jumpToPage?(target.chapter)
        }
    }

    /// Where "Back" returns to, most recent last.
    private(set) var backStack: [ReadingPosition] = []

    var bookmarks: [Bookmark] = []

    // Highlights
    var highlights: [Highlight] = []
    var tappedHighlight: Highlight?
    private(set) var highlightLocationDescription = ""
    @ObservationIgnored private var highlightBook: BookHighlights?
    @ObservationIgnored private let highlightStore: HighlightStore
    @ObservationIgnored private var documentID: String?

    /// Set by the active viewer so toolbar controls can navigate.
    @ObservationIgnored var jumpToPage: ((Int) -> Void)?
    /// Reflowable viewers supply the text around the visible part of a (possibly very long) chapter.
    @ObservationIgnored var visibleText: (@MainActor () async -> String?)?
    /// The viewer turns its current selection into a highlight location (+ the exact text).
    @ObservationIgnored var captureSelection: (@MainActor () async -> (Highlight.Location, String)?)?
    @ObservationIgnored var clearSelection: (@MainActor () -> Void)?
    @ObservationIgnored var revealHighlight: (@MainActor (Highlight) -> Void)?
    @ObservationIgnored private var ocrTask: Task<Void, Never>?
    @ObservationIgnored private var lastAskedAbout: (page: Int, selection: String)?

    var pdfDocument: PDFDocument? { (source as? PDFPageSource)?.document }
    var reflowable: ReflowableSource? { source as? ReflowableSource }

    /// Opening can be slow (EPUB extraction, FB2 conversion, DjVu index), so it runs off the main actor.
    static func load(book: Book, startPage: Int, startProgress: Double, ocrLanguages: [String],
                     highlightStore: HighlightStore) async throws -> ReaderModel {
        let url = book.url
        let source = try await Task.detached(priority: .userInitiated) { try DocumentOpener.open(url) }.value
        let model = ReaderModel(book: book, source: source, startPage: startPage, ocrLanguages: ocrLanguages,
                                highlightStore: highlightStore)
        model.startProgress = startProgress
        model.pageProgress = startProgress
        await model.loadHighlights()
        return model
    }

    init(book: Book, source: PageSource, startPage: Int, ocrLanguages: [String], highlightStore: HighlightStore) {
        self.book = book
        self.source = source
        self.highlightStore = highlightStore
        text = TextProvider(source: source, ocr: OCRService(languages: ocrLanguages))
        currentPage = min(max(0, startPage), max(0, source.pageCount - 1))
        imageMode = book.isDjVu || Self.looksScanned(source)
        installFixedLayoutSpeech()
    }

    /// A PDF whose first pages have no text layer is almost certainly a scan.
    private static func looksScanned(_ source: PageSource) -> Bool {
        guard source is PDFPageSource, source.pageCount > 0 else { return false }
        let probe = (0..<min(3, source.pageCount))
        return probe.allSatisfy { source.embeddedText(at: $0) == nil }
    }

    /// - Parameter remember: false for step-wise moves (chapter arrows) that don't belong in the back stack.
    func go(to page: Int, remember: Bool = true) {
        let page = min(max(0, page), source.pageCount - 1)
        if remember { pushCurrentPosition() }
        jumpToPage?(page)
        currentPage = page
    }

    // MARK: Read aloud (fixed layout)

    /// PDF/DjVu/scans read page by page. The anchor is the page; ranges are into that page's text.
    /// Reflowable viewers replace both closures with their own.
    private func installFixedLayoutSpeech() {
        guard reflowable == nil else { return }
        speechParagraphs = { [weak self] restart in
            guard let self else { return [] }
            if restart { speechPage = currentPage } else { speechPage += 1 }
            while speechPage < source.pageCount {
                if let text = await speechText(page: speechPage), text.rangeOfCharacter(from: .letters) != nil {
                    return [(text, speechPage)]
                }
                speechPage += 1   // blank page: skip
            }
            return []
        }
        speechHighlight = { [weak self] page, _ in
            guard let self, page >= 0, page != currentPage else { return }
            jumpToPage?(page)
            currentPage = page
        }
    }

    /// Page text with line breaks turned into spaces (same length, so offsets stay valid for PDF selections).
    func speechText(page: Int) async -> String? {
        if let pdf = pdfDocument?.page(at: page)?.string, !imageMode {
            return pdf.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        return try? await text.text(page: page, allowOCR: true)?.plainText.replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Read Later

    func addToReadLater(url: URL, title: String?) {
        let source = "\(book.title), \(currentPosition.label)"
        let name = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (url.host().map { $0 + url.path() } ?? url.absoluteString)
        Task {
            let added = await Task.detached(priority: .userInitiated) {
                let list = ReadLaterList(file: InboxLocation.readLaterFile())
                return try? list.add(.init(title: name, url: url.absoluteString, source: source))
            }.value
            switch added {
            case true?: statusMessage = "Added to Read Later"
            case false?: statusMessage = "Already in Read Later"
            case nil: statusMessage = "Couldn't save to Read Later"
            }
        }
    }

    // MARK: Back stack

    var currentPosition: ReadingPosition {
        let label = reflowable == nil ? "p. \(currentPage + 1)" : "p. \(globalPage)"
        return ReadingPosition(page: currentPage, progress: pageProgress, label: label)
    }

    /// Remembers where the reader is before a jump (link, contents, page number).
    func pushCurrentPosition() {
        let here = currentPosition
        guard backStack.last != here else { return }
        backStack.append(here)
        if backStack.count > 30 { backStack.removeFirst() }
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        if reflowable != nil, let jumpToPosition {
            jumpToPosition(target.page, target.progress)
        } else {
            jumpToPage?(target.page)
            currentPage = target.page
        }
    }

    func clearBackStack() { backStack = [] }

    // MARK: Highlights

    private func loadHighlights() async {
        let url = book.url
        guard let id = try? await Task.detached(priority: .utility, operation: { try DocumentFingerprint.id(for: url) }).value
        else { return }
        documentID = id
        let stored = await highlightStore.load(documentID: id)
        highlightBook = stored ?? BookHighlights(documentID: id, title: book.title, fileName: book.url.lastPathComponent)
        highlights = highlightBook?.highlights ?? []
        bookmarks = highlightBook?.bookmarks ?? []
        highlightLocationDescription = await highlightStore.textFolderDescription
    }

    /// Highlights the current selection in `color`.
    func addHighlight(color: Highlight.Color = .yellow) async {
        guard let captured = await captureSelection?() else {
            statusMessage = "Couldn't place that highlight — try selecting the text again."
            return
        }
        let highlight = Highlight(text: captured.1, color: color, location: captured.0)
        highlightBook?.highlights.append(highlight)
        highlightBook?.highlights.sort(by: { BookHighlights.readingOrderPublic($0, $1) })
        highlights = highlightBook?.highlights ?? []
        clearSelection?()
        selection = ""
        await persistHighlights()
    }

    func removeHighlight(_ highlight: Highlight) async {
        highlightBook?.highlights.removeAll { $0.id == highlight.id }
        highlightBook?.deleted.insert(highlight.id)
        highlights = highlightBook?.highlights ?? []
        await persistHighlights()
    }

    func recolor(_ highlight: Highlight, to color: Highlight.Color) async {
        guard let i = highlightBook?.highlights.firstIndex(where: { $0.id == highlight.id }) else { return }
        // A colour change is a new highlight id so the merge can't resurrect the old colour.
        var updated = highlight
        updated.id = UUID()
        updated.color = color
        highlightBook?.highlights[i] = updated
        highlightBook?.deleted.insert(highlight.id)
        highlights = highlightBook?.highlights ?? []
        await persistHighlights()
    }

    func reveal(_ highlight: Highlight) {
        if let revealHighlight {
            revealHighlight(highlight)
        } else {
            go(to: highlight.location.pageIndex)
        }
    }

    func locationLabel(_ location: Highlight.Location) -> String {
        Self.label(location, chapterTitles: reflowable?.chapterTitles)
    }

    nonisolated static func label(_ location: Highlight.Location, chapterTitles: [String]?) -> String {
        switch location {
        case .pdf(let rects): "p. \((rects.first?.page ?? 0) + 1)"
        case .image(let page, _): "p. \(page + 1)"
        case .text(let chapter, _, _, _, _):
            chapterTitles.flatMap { $0.indices.contains(chapter) ? $0[chapter] : nil } ?? "Chapter \(chapter + 1)"
        }
    }

    // MARK: Bookmarks

    /// 1-based page (whole book for reflowable) a bookmark points at.
    func page(of bookmark: Bookmark) -> Int {
        guard reflowable != nil else { return bookmark.page + 1 }
        let pages = chapterPages
        guard pages.indices.contains(bookmark.page) else { return 1 }
        return pages[..<bookmark.page].reduce(0, +) + Int((bookmark.progress * Double(max(0, pages[bookmark.page] - 1))).rounded()) + 1
    }

    var currentBookmark: Bookmark? {
        bookmarks.first { reflowable == nil ? $0.page == currentPage : page(of: $0) == globalPage }
    }

    func toggleBookmark() async {
        if let existing = currentBookmark {
            highlightBook?.bookmarks.removeAll { $0.id == existing.id }
            highlightBook?.deleted.insert(existing.id)
        } else {
            let snippet = await pageSnippet()
            let mark = Bookmark(page: currentPage, progress: reflowable == nil ? 0 : pageProgress,
                                label: currentPosition.label, snippet: snippet)
            highlightBook?.bookmarks.append(mark)
        }
        bookmarks = highlightBook?.bookmarks ?? []
        await persistHighlights()
    }

    func removeBookmark(_ bookmark: Bookmark) async {
        highlightBook?.bookmarks.removeAll { $0.id == bookmark.id }
        highlightBook?.deleted.insert(bookmark.id)
        bookmarks = highlightBook?.bookmarks ?? []
        await persistHighlights()
    }

    func open(_ bookmark: Bookmark) {
        pushCurrentPosition()
        if reflowable != nil, let jumpToPosition {
            jumpToPosition(bookmark.page, bookmark.progress)
        } else {
            jumpToPage?(bookmark.page)
            currentPage = bookmark.page
        }
    }

    /// First words on the current page, so a bookmark is recognisable in lists and searchable.
    private func pageSnippet() async -> String {
        var text: String?
        if let visibleText { text = await visibleText() }
        if text?.isEmpty ?? true { text = await self.text.availableText(page: currentPage)?.plainText }
        let words = (text ?? "").split(whereSeparator: \.isWhitespace).prefix(18).joined(separator: " ")
        return words.isEmpty ? "Page \(currentPosition.label)" : words + ((text?.count ?? 0) > words.count ? "…" : "")
    }

    private func persistHighlights() async {
        guard var book = highlightBook else { return }
        book.path = String(self.book.url.standardizedFileURL.path.dropFirst(LibraryStore.rootURL.path.count + 1))
        let titles = reflowable?.chapterTitles
        do {
            let merged = try await highlightStore.save(book) { Self.label($0, chapterTitles: titles) }
            highlightBook = merged
            highlights = merged.highlights
            bookmarks = merged.bookmarks
        } catch {
            statusMessage = "Couldn't save highlights: \(error.localizedDescription)"
        }
    }

    // MARK: Assistant

    func ask(_ question: String, action: QuickAction? = nil, settings: SettingsStore) {
        let provider: LLMProvider
        do { provider = try settings.makeProvider() } catch {
            chat.error = error.localizedDescription
            return
        }
        chat.notice = nil
        let selection = action == .summarize ? "" : questionSelection
        let display = action.map { action in
            guard !selection.isEmpty else { return action.title }
            let separator = action.title.hasSuffix("?") ? " " : ": "
            return "\(action.title)\(separator)“\(selection.prefix(120))”"
        }
            ?? (selection.isEmpty ? question : "“\(selection.prefix(80))\(selection.count > 80 ? "…" : "")” — \(question)")
        let prompt = action?.question(selection: selection, language: settings.llm.answerLanguage) ?? question

        // Re-send page context when the reader moved or selected something new since the last question.
        let needsContext = chat.turns.isEmpty || lastAskedAbout?.page != currentPage || action == .summarize
            || (!selection.isEmpty && lastAskedAbout?.selection != selection)

        let page = currentPage
        let title = book.title
        let system = ReadingAssistant.systemPrompt(answerLanguage: settings.llm.answerLanguage)
        Task {
            var message = prompt
            var sentContext: String?
            if needsContext {
                let surrounding = await pageContext(budget: provider.contextCharacterBudget, wide: provider.contextCharacterBudget > 20_000)
                // Nothing to read (a scan that hasn't been recognised): say so rather than let the model invent.
                if surrounding.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 && selection.isEmpty {
                    chat.notice = .noText
                    return
                }
                // Apple's on-device model only understands some languages; anything else comes back as junk.
                if provider is AppleOnDeviceProvider,
                   let language = SpeechPlanner.detectLanguage(selection.isEmpty ? surrounding : selection + " " + surrounding),
                   !AppleOnDeviceProvider.supports(language: language) {
                    chat.notice = .unsupportedLanguage(Locale.current.localizedString(forLanguageCode: language) ?? language)
                    return
                }
                let context = ReadingContext(documentTitle: title, pageIndex: page,
                                             selection: selection.isEmpty ? nil : selection, surroundingText: surrounding)
                message = ReadingAssistant.firstMessage(question: prompt, context: context)
                sentContext = surrounding
            }
            lastAskedAbout = (page, selection)
            chat.send(display: display, provider: provider, system: system, sentContext: sentContext) { message }
        }
    }

    /// Text around the reader's position: what is on screen for reflowable books, the page (± neighbours) otherwise.
    private func pageContext(budget: Int, wide: Bool) async -> String {
        if let visible = await visibleText?(), !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(visible.prefix(budget))
        }
        return await text.context(around: currentPage, radius: wide ? 1 : 0, characterBudget: budget, allowOCR: true)
    }

    // MARK: OCR

    func recognizeCurrentPage() {
        let page = currentPage
        statusMessage = "Recognizing page \(page + 1)…"
        Task {
            do {
                let result = try await text.recognize(page: page)
                statusMessage = "Page \(page + 1): \(result.plainText.split(whereSeparator: \.isWhitespace).count) words recognized"
            } catch {
                statusMessage = "OCR failed: \(error.localizedDescription)"
            }
        }
    }

    /// OCRs every page without text so the assistant (and future search) can use the whole book.
    func recognizeDocument() {
        ocrTask?.cancel()
        let total = source.pageCount
        ocrProgress = 0
        ocrTask = Task {
            for page in 0..<total {
                if Task.isCancelled { break }
                _ = try? await text.text(page: page, allowOCR: true)
                ocrProgress = Double(page + 1) / Double(total)
            }
            statusMessage = Task.isCancelled ? "Recognition stopped" : "Recognized \(total) pages"
            ocrProgress = nil
        }
    }

    func cancelRecognition() {
        ocrTask?.cancel()
        ocrProgress = nil
    }
}

@MainActor @Observable
final class ChatModel {
    struct Turn: Identifiable {
        let id = UUID()
        var role: ChatMessage.Role
        var display: String
        var wire: String
        /// Page text sent with this question (shown under it, so answers can be checked).
        var context: String?
    }

    /// Why a question wasn't sent (shown as a card with a way out).
    enum Notice: Equatable {
        case noText
        case unsupportedLanguage(String)
    }

    var turns: [Turn] = []
    var isStreaming = false
    var error: String?
    var notice: Notice?
    @ObservationIgnored private var task: Task<Void, Never>?

    func send(display: String, provider: LLMProvider, system: String, sentContext: String? = nil,
              buildPrompt: @escaping @MainActor () async -> String) {
        task?.cancel()
        error = nil
        isStreaming = true
        let user = Turn(role: .user, display: display, wire: display, context: sentContext)
        let reply = Turn(role: .assistant, display: "", wire: "")
        turns.append(user)
        turns.append(reply)

        task = Task {
            let prompt = await buildPrompt()
            update(user.id) { $0.wire = prompt }
            let history = turns.prefix { $0.id != reply.id }.map { ChatMessage(role: $0.role, content: $0.wire) }
            do {
                for try await delta in provider.stream(system: system, messages: Array(history)) {
                    update(reply.id) { $0.display += delta }
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            update(reply.id) { $0.wire = $0.display }
            turns.removeAll { $0.id == reply.id && $0.display.isEmpty }
            if !Task.isCancelled { isStreaming = false }
        }
    }

    /// Turns may be cleared while a reply streams, so address them by id, not index.
    private func update(_ id: UUID, _ change: (inout Turn) -> Void) {
        if let i = turns.firstIndex(where: { $0.id == id }) { change(&turns[i]) }
    }

    func stop() {
        task?.cancel()
        isStreaming = false
    }

    func clear() {
        stop()
        turns = []
        error = nil
        notice = nil
    }
}
