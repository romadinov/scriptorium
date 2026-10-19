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
        didSet {
            if !selection.isEmpty { questionSelection = selection }
            if selection != oldValue { refreshSelectionAnchor() }
        }
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
    /// Page to start from when reading restarts at a tapped word (fixed layout).
    @ObservationIgnored private var speechStartPage: Int?
    /// Viewers that need to know (e.g. to turn taps into "read from here") listen here.
    @ObservationIgnored var readingAloudChanged: (@MainActor (Bool) -> Void)?

    var isReadingAloud: Bool { readAloud.state != .idle }

    /// Tap on a word while reading aloud: carry on from that word.
    func readAloud(fromAnchor anchor: Int, offset: Int) {
        guard isReadingAloud else { return }
        if reflowable == nil { speechStartPage = anchor }
        readAloud.start(self, from: (anchor, offset))
    }

    /// Fixed-layout image pages (DjVu, scans): find the tapped word in the page's text.
    func readAloud(fromPage page: Int, normalizedPoint point: CGPoint) {
        guard isReadingAloud else { return }
        Task {
            guard let pageText = await text.availableText(page: page),
                  let offset = pageText.characterOffset(at: point) else { return }
            readAloud(fromAnchor: page, offset: offset)
        }
    }

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
    /// Previous/next screen in a reflowable book's paged layout (keyboard on the Mac).
    @ObservationIgnored var turnPage: ((Int) -> Void)?

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
    /// A newer position saved on another device, offered to the reader ("Continue on p. 120 from Mac?").
    var remotePosition: SyncedPosition?
    @ObservationIgnored private var positionSave: Task<Void, Never>?
    /// The highlight or page whose note is being edited.
    var annotating: AnnotationTarget? { didSet { if annotating != nil { pausePace() } } }
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
                     highlightStore: HighlightStore, asText: Bool = false) async throws -> ReaderModel {
        let url = book.url
        try await WordDocConverter.convertIfNeeded(url)   // .doc: one-time conversion with WebKit
        var source = try await Task.detached(priority: .userInitiated) { try DocumentOpener.open(url) }.value
        // PDF/DjVu "View as Text": the same pages, converted to reflowable text (one chapter per page).
        if asText, source is PDFPageSource || source is DjVuPageSource { source = ReflowedSource(original: source) }
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
        self.ocrLanguages = ocrLanguages
        currentPage = min(max(0, startPage), max(0, source.pageCount - 1))
        imageMode = !(source is ReflowedSource) && (book.isDjVu || Self.looksScanned(source))
        installFixedLayoutSpeech()
    }

    // MARK: View as Text (PDF/DjVu converted to reflowable text)

    /// "View as Text" is remembered per book.
    static func viewsAsText(_ book: Book) -> Bool { UserDefaults.standard.bool(forKey: "asText:" + book.url.lastPathComponent) }
    static func setViewsAsText(_ on: Bool, for book: Book) { UserDefaults.standard.set(on, forKey: "asText:" + book.url.lastPathComponent) }

    @ObservationIgnored private let ocrLanguages: [String]
    var canViewAsText: Bool { source is PDFPageSource || source is DjVuPageSource }
    var isViewingAsText: Bool { source is ReflowedSource }
    /// Converting pages to text: fraction done, nil when idle.
    var textConversion: Double?
    @ObservationIgnored private var conversionTask: Task<Void, Never>?
    /// Reloads a chapter whose placeholder is showing once its page has been converted (set by the viewer).
    @ObservationIgnored var reloadChapter: (@MainActor (Int) -> Void)?

    /// Converts the remaining pages, from the current one on; the page being read is redrawn when ready.
    func convertToText() {
        guard let reflowed = source as? ReflowedSource, conversionTask == nil, reflowed.convertedCount < reflowed.pageCount else { return }
        let languages = ocrLanguages
        textConversion = Double(reflowed.convertedCount) / Double(max(1, reflowed.pageCount))
        conversionTask = Task { [weak self] in
            do {
                try await reflowed.convert(from: self?.currentPage ?? 0, languages: languages) { fraction, page in
                    await MainActor.run {
                        guard let self else { return }
                        self.textConversion = fraction
                        if abs(page - self.currentPage) <= 1 { self.reloadChapter?(page) }
                    }
                }
            } catch {}
            self?.textConversion = nil
            self?.conversionTask = nil
        }
    }

    func stopTextConversion() {
        conversionTask?.cancel()
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
            if restart {
                speechPage = speechStartPage ?? currentPage
                speechStartPage = nil
            } else {
                speechPage += 1
            }
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

    /// Page text without running headers/footers, line breaks turned into spaces. Both keep the
    /// length, so offsets stay valid for PDF selections and the spoken-sentence highlight.
    func speechText(page: Int) async -> String? {
        let raw: String
        let neighbours: [String]
        if let pdf = pdfDocument, let string = pdf.page(at: page)?.string, !imageMode {
            raw = string
            neighbours = [page - 2, page - 1, page + 1, page + 2]
                .filter { $0 >= 0 && $0 < pdf.pageCount }
                .compactMap { pdf.page(at: $0)?.string }
        } else {
            guard let ocr = try? await text.text(page: page, allowOCR: true)?.plainText else { return nil }
            raw = ocr
            neighbours = await text.neighbourTexts(of: page)
        }
        return RunningHeaders.blanked(raw, neighbours: neighbours)
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: Reading pace

    /// This book's pace (pages are denser in some books than others); the overall pace stands in until it's known.
    private(set) var pace = ReadingPace()
    @ObservationIgnored private var overallPace = ReadingPace()
    @ObservationIgnored private var lastTurn: (page: Int, at: Date)?
    /// Pages already timed or passed: going back and forward over them again isn't new reading.
    @ObservationIgnored private var furthestTimedPage = -1
    @ObservationIgnored private var paceKey: String { "pace:" + (documentID ?? book.url.lastPathComponent) }

    private func loadPace() {
        let decoder = JSONDecoder()
        pace = UserDefaults.standard.data(forKey: paceKey).flatMap { try? decoder.decode(ReadingPace.self, from: $0) } ?? ReadingPace()
        overallPace = UserDefaults.standard.data(forKey: "pace:all").flatMap { try? decoder.decode(ReadingPace.self, from: $0) } ?? ReadingPace()
    }

    /// Times each step forward by one page, or by a two-page spread (PDFs side by side on iPad, timed per page);
    /// skimming, pauses and jumps don't count.
    func notePageTurn() {
        let page = readingPageNumber, now = Date()
        defer { lastTurn = (page, now) }
        defer { furthestTimedPage = max(furthestTimedPage, page) }
        guard let last = lastTurn, page - last.page == 1 || page - last.page == 2, page > furthestTimedPage else { return }
        let seconds = now.timeIntervalSince(last.at) / Double(page - last.page)
        guard pace.record(seconds) else { return }
        overallPace.record(seconds)
        let encoder = JSONEncoder()
        UserDefaults.standard.set(try? encoder.encode(pace), forKey: paceKey)
        UserDefaults.standard.set(try? encoder.encode(overallPace), forKey: "pace:all")
    }

    /// The app went to the background, or a suggestion/note/assistant is open: that time isn't reading time.
    func pausePace() { lastTurn = nil }

    /// Time to finish the book at your pace (nil until a few pages have been timed).
    var timeLeft: TimeInterval? {
        // On unless switched off (launch arguments arrive as strings, so read it with bool(forKey:)).
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "showTimeLeft") == nil || defaults.bool(forKey: "showTimeLeft") else { return nil }
        let total = reflowable == nil ? source.pageCount : totalPages
        return pace.timeLeft(pages: total - readingPageNumber, fallback: overallPace)
    }

    var timeLeftText: String? { timeLeft.map { ReadingPace.describe($0) + " left" } }

    /// "1.2 min a page" (or seconds), for the page picker.
    var paceText: String? {
        guard let seconds = pace.secondsPerPage ?? overallPace.secondsPerPage else { return nil }
        return seconds < 90 ? "\(Int(seconds.rounded())) s a page" : String(format: "%.1f min a page", seconds / 60)
    }

    // MARK: Synced position

    /// Looks for a newer position from another device (on open, and when the app comes back).
    func checkRemotePosition(localSavedAt: Date?) async {
        guard let documentID else { return }
        let others = await PositionStore.shared.others(documentID: documentID, excluding: DeviceIdentity.id)
        guard let newest = others.first,
              newest.shouldOffer(over: currentPage, reflowable == nil ? 0 : pageProgress, savedAt: localSavedAt) else { return }
        remotePosition = newest
    }

    func acceptRemotePosition() {
        guard let target = remotePosition else { return }
        remotePosition = nil
        pushCurrentPosition()
        if reflowable != nil, let jumpToPosition {
            jumpToPosition(target.page, target.progress)
        } else {
            jumpToPage?(target.page)
            currentPage = target.page
        }
    }

    /// "Stay": keep reading here, and tell the other devices this is now the latest place.
    func declineRemotePosition() {
        remotePosition = nil
        publishPosition(after: .zero)
    }

    /// Shares where this device is, a few seconds after the reader stops moving (not on every page turn).
    func publishPosition(after delay: Duration = .seconds(4)) {
        guard let documentID else { return }
        positionSave?.cancel()
        positionSave = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            let position = SyncedPosition(page: currentPage, progress: reflowable == nil ? 0 : pageProgress,
                                          label: currentPosition.label, device: DeviceIdentity.name, deviceID: DeviceIdentity.id)
            await PositionStore.shared.save(position, documentID: documentID)
        }
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
        awaitingLanding = true
        landingPage = nil
    }

    /// Page number used to tell whether the reader has moved on after a jump.
    var readingPageNumber: Int { reflowable == nil ? currentPage + 1 : globalPage }

    @ObservationIgnored private var landingPage: Int?
    @ObservationIgnored private var awaitingLanding = false

    /// Called on every page change. The first change after a jump is where the reader landed; once they
    /// read on two pages from there, "Back" is no longer wanted and the stack is dropped (as in Books).
    func noteReadingPosition() {
        guard !backStack.isEmpty else { return }
        let page = readingPageNumber
        if awaitingLanding || landingPage == nil {
            landingPage = page
            awaitingLanding = false
        } else if let landing = landingPage, abs(page - landing) >= 2 {
            backStack = []
            landingPage = nil
        }
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        awaitingLanding = true
        landingPage = nil
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
        loadPace()
    }

    /// Highlights the current selection in `color`.
    @discardableResult
    func addHighlight(color: Highlight.Color = .yellow) async -> Highlight? {
        guard let captured = await captureSelection?() else {
            statusMessage = "Couldn't place that highlight — try selecting the text again."
            return nil
        }
        let highlight = Highlight(text: captured.1, color: color, location: captured.0)
        highlightBook?.highlights.append(highlight)
        highlightBook?.highlights.sort(by: { BookHighlights.readingOrderPublic($0, $1) })
        highlights = highlightBook?.highlights ?? []
        clearSelection?()
        selection = ""
        await persistHighlights()
        return highlight
    }

    func removeHighlight(_ highlight: Highlight) async {
        if let drawing = highlight.drawingID { await highlightStore.deleteDrawing(id: drawing) }
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

    /// Where the current selection is, as a quote with context, so links land on the passage itself.
    @ObservationIgnored private(set) var selectionAnchor: (selection: String, page: Int, quote: TextQuote)?
    @ObservationIgnored private var anchorTask: Task<Void, Never>?
    /// Finds and selects a quoted passage near `page` (the viewers set it); false if it isn't found.
    @ObservationIgnored var findQuote: (@MainActor (TextQuote, Int) async -> Bool)?

    private func refreshSelectionAnchor() {
        anchorTask?.cancel()
        let selected = selection
        guard !selected.isEmpty else { selectionAnchor = nil; return }
        anchorTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil, let self,
                  let (location, text) = await self.captureSelection?() else { return }
            let anchor: (Int, TextQuote)?
            switch location {
            case .text(let chapter, _, _, let prefix, let suffix):
                anchor = (chapter, TextQuote(selection: text, in: prefix + text + suffix))
            case .pdf(let rects):
                let page = rects.first?.page ?? self.currentPage
                anchor = (page, await self.quote(text, onPage: page))
            case .image(let page, _):
                anchor = (page, await self.quote(text, onPage: page))
            }
            guard !Task.isCancelled, self.selection == selected, let anchor else { return }
            self.selectionAnchor = (selected, anchor.0, anchor.1)
        }
    }

    private func quote(_ selected: String, onPage page: Int) async -> TextQuote {
        let pageText = (try? await text.text(page: page, allowOCR: false))?.plainText ?? ""
        return TextQuote(selection: selected, in: pageText)
    }

    /// Lands on a quoted passage (from a link): the viewer finds and selects it; else just its page.
    func reveal(_ quote: TextQuote, page: Int) async {
        // The viewer may still be laying out (web views load chapters asynchronously): retry for a few seconds.
        for _ in 0..<10 {
            if let findQuote, await findQuote(quote, page) { return }
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
        }
        go(to: page)
    }

    /// What "Send Link to <task app>" stores for a link in the book: web links as they are; links within the
    /// book as a Scriptorium link to their target chapter.
    func taskAppLink(for url: URL, title: String?, scheme: String = TaskAppLink.scheme) -> URL? {
        guard let here = readingLink(), let documentID else { return nil }
        let note = "From \(here.title)\n\(here.url.absoluteString)"
        if url.isFileURL || url.scheme == "applewebdata" {
            guard let chapter = reflowable?.chapterIndex(for: url) else { return nil }
            let target = DeepLink(documentID: documentID, page: chapter).url
            let name = title ?? reflowable.flatMap { $0.chapterTitles.indices.contains(chapter) ? $0.chapterTitles[chapter] : nil }
            return TaskAppLink.add(title: ReadingLocationTitle.make(book: book.title, page: chapter, chapterTitle: name),
                                       url: target, note: note, scheme: scheme)
        }
        return TaskAppLink.add(title: title ?? url.host() ?? url.absoluteString, url: url, note: note, scheme: scheme)
    }

    /// A link to where the reader is (or to `highlight`), titled "Book — p. N" / "Book — Chapter", for the task app,
    /// the share sheet and Copy Link. Nil until the book's fingerprint is known.
    func readingLink(highlight: Highlight? = nil) -> (url: URL, title: String, text: String)? {
        guard let documentID else { return nil }
        // A selection that is exactly a highlight on this page counts as selecting that highlight.
        let highlight = highlight ?? (selection.isEmpty ? nil : highlights.first {
            $0.text == selection && $0.location.pageIndex == currentPage
        })
        // A plain selection links to the passage itself (quote + context), found again on open.
        let anchor = highlight == nil ? selectionAnchor.flatMap { $0.selection == selection ? $0 : nil } : nil
        let page = highlight?.location.pageIndex ?? anchor?.page ?? currentPage
        let progress = highlight != nil || (anchor != nil && (reflowable == nil || page != currentPage)) ? 0 : pageProgress
        let link = DeepLink(documentID: documentID, page: page, progress: progress,
                            highlightID: highlight?.id, quote: anchor?.quote)
        let chapter = reflowable.flatMap { $0.chapterTitles.indices.contains(page) ? $0.chapterTitles[page] : "Chapter \(page + 1)" }
        let title = ReadingLocationTitle.make(book: book.title, page: page, chapterTitle: chapter)
        let text = [highlight?.text ?? selection, highlight?.note ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (link.url, title, text)
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
            await removeBookmark(existing)
            return
        }
        await addBookmark()
    }

    @discardableResult
    private func addBookmark() async -> Bookmark {
        let snippet = await pageSnippet()
        let mark = Bookmark(page: currentPage, progress: reflowable == nil ? 0 : pageProgress,
                            label: currentPosition.label, snippet: snippet)
        highlightBook?.bookmarks.append(mark)
        bookmarks = highlightBook?.bookmarks ?? []
        await persistHighlights()
        return mark
    }

    // MARK: Annotations

    /// Highlights the selection and opens a note on it.
    func annotateSelection() async {
        guard let highlight = await addHighlight() else { return }
        annotating = .highlight(highlight)
    }

    /// Opens the note for the current page (a page note lives on the page's bookmark).
    func annotatePage() async {
        let mark = if let currentBookmark { currentBookmark } else { await addBookmark() }
        annotating = .bookmark(mark)
    }

    func loadDrawing(_ id: UUID) async -> Data? {
        await highlightStore.loadDrawing(id: id)
    }

    /// Saves a note. `drawing` is nil when the drawing wasn't touched; `.some(nil)` removes it.
    func saveAnnotation(_ target: AnnotationTarget, note: String, drawing: (data: Data, png: Data?)??) async {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var drawingID = target.item.drawingID
        if let drawing {
            if let old = drawingID { await highlightStore.deleteDrawing(id: old) }
            drawingID = nil
            if let drawing {
                let id = UUID()
                do {
                    try await highlightStore.saveDrawing(id: id, data: drawing.data, png: drawing.png)
                    drawingID = id
                } catch {
                    statusMessage = "Couldn't save the drawing: \(error.localizedDescription)"
                }
            }
        }
        func update<T: Annotatable>(_ item: inout T) {
            item.note = trimmed.isEmpty ? nil : trimmed
            item.drawingID = drawingID
            item.modified = Date()
        }
        switch target {
        case .highlight(let h):
            guard let i = highlightBook?.highlights.firstIndex(where: { $0.id == h.id }) else { return }
            update(&highlightBook!.highlights[i])
        case .bookmark(let b):
            guard let i = highlightBook?.bookmarks.firstIndex(where: { $0.id == b.id }) else { return }
            update(&highlightBook!.bookmarks[i])
        }
        highlights = highlightBook?.highlights ?? []
        bookmarks = highlightBook?.bookmarks ?? []
        await persistHighlights()
    }

    func removeBookmark(_ bookmark: Bookmark) async {
        if let drawing = bookmark.drawingID { await highlightStore.deleteDrawing(id: drawing) }
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
                    // Small models sometimes repeat one sentence forever; cut the loop off.
                    if let text = turns.first(where: { $0.id == reply.id })?.display, RepetitionGuard.isLooping(text) {
                        update(reply.id) { $0.display = RepetitionGuard.trimmed($0.display) }
                        break
                    }
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

/// What a note is attached to.
enum AnnotationTarget: Identifiable, Equatable {
    case highlight(Highlight)
    case bookmark(Bookmark)

    var id: UUID { item.id }

    var item: any Annotatable {
        switch self {
        case .highlight(let h): h
        case .bookmark(let b): b
        }
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}
