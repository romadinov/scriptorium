import ReaderCore
import SwiftUI
import WebKit

enum ReflowLayout: String, CaseIterable, Identifiable {
    case paged, scroll
    var id: String { rawValue }
    var title: String { self == .paged ? "Pages (swipe)" : "Scroll" }
    var systemImage: String { self == .paged ? "book.pages" : "scroll" }
}

/// EPUB/FB2 viewer: one continuous document (see ReflowEngine.js) with chapters loaded around
/// the reading position, laid out as horizontally swiped pages or a vertical scroll.
#if os(macOS)
struct ReflowableView: NSViewRepresentable {
    let model: ReaderModel
    let book: ReflowableSource
    let layout: ReflowLayout
    let fontScale: Double
    /// Adds the reader's items (Highlight, Note, Ask…) to the right-click menu; `link` is the link under the mouse.
    var contextMenu: ((NSMenu, _ link: URL?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(model: model, book: book, layout: layout) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = makeWebView(context: context)
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.extendMenu = { [weak coordinator = context.coordinator] menu in
            coordinator?.contextMenu?(menu, coordinator?.lastContextLink)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.contextMenu = contextMenu
        update(context: context)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        dismantle(webView, coordinator: coordinator)
    }
}
#else
struct ReflowableView: UIViewRepresentable {
    let model: ReaderModel
    let book: ReflowableSource
    let layout: ReflowLayout
    let fontScale: Double

    func makeCoordinator() -> Coordinator { Coordinator(model: model, book: book, layout: layout) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = makeWebView(context: context)
        webView.configuration.dataDetectorTypes = []
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        let scrollView = webView.scrollView
        if layout == .paged {
            // The page owns the full height; the native scroll view snaps one screen per swipe.
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.isPagingEnabled = true
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.alwaysBounceVertical = false
            scrollView.bounces = true
        } else {
            scrollView.contentInsetAdjustmentBehavior = .automatic
            scrollView.showsHorizontalScrollIndicator = false
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        update(context: context)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        dismantle(webView, coordinator: coordinator)
    }
}
#endif

extension ReflowableView {
    @MainActor
    fileprivate func makeWebView(context: Context) -> ReaderWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.engine, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(WeakMessageHandler(context.coordinator), name: "reader")
        let webView = ReaderWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isInspectable = true
        context.coordinator.webView = webView
        context.coordinator.fontScale = fontScale
        context.coordinator.install()
        context.coordinator.loadShell()
        webView.onSizeChange = { [weak coordinator = context.coordinator] _ in coordinator?.repaginate() }
        return webView
    }

    @MainActor
    fileprivate func update(context: Context) {
        let coordinator = context.coordinator
        if coordinator.fontScale != fontScale {
            coordinator.fontScale = fontScale
            coordinator.call("reader.configure({scale: s})", ["s": fontScale])
            coordinator.repaginate()
        }
        coordinator.sync(highlights: model.highlights)
    }

    @MainActor
    fileprivate static func dismantle(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        coordinator.uninstall()
        coordinator.paginator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let model: ReaderModel
        let book: ReflowableSource
        let layout: ReflowLayout
        weak var webView: WKWebView?
        var fontScale = 1.0
        private var ready = false
        private var syncedHighlights: [Highlight] = []
        private var loading: Set<Int> = []
        let paginator: Paginator
        #if os(macOS)
        var contextMenu: ((NSMenu, URL?) -> Void)?
        /// The link under the mouse at the last right-click (reported by the page before the menu opens).
        var lastContextLink: URL?
        #endif

        init(model: ReaderModel, book: ReflowableSource, layout: ReflowLayout) {
            self.model = model
            self.book = book
            self.layout = layout
            paginator = Paginator(book: book, layout: layout)
            super.init()
            paginator.onMeasured = { [weak model] chapter, pages in model?.measuredPages[chapter] = pages }
        }

        /// Starts (or restarts) page counting for the current viewport and font.
        func repaginate() {
            guard ready, let webView, let host = webView.superview else { return }
            var size = webView.bounds.size
            #if os(iOS)
            if layout == .scroll {
                let insets = webView.scrollView.adjustedContentInset
                size.height -= insets.top + insets.bottom
            }
            #endif
            model.measuredPages = [:]
            paginator.start(in: host, size: size, scale: fontScale)
        }

        // MARK: Wiring to the model

        func install() {
            model.jumpToPage = { [weak self] index in self?.go(to: index, progress: 0, fragment: nil) }
            model.jumpToPosition = { [weak self] chapter, progress in self?.go(to: chapter, progress: progress, fragment: nil) }
            model.turnPage = { [weak self] delta in self?.turnPage(delta) }
            // Text lengths drive page estimates until the paginator has real counts.
            let book = book
            Task { [weak model] in
                let lengths = await Task.detached(priority: .utility) {
                    (0..<book.pageCount).map { book.embeddedText(at: $0)?.plainText.count ?? 0 }
                }.value
                model?.chapterLengths = lengths
            }
            model.visibleText = { [weak self] in
                try? await self?.webView?.evaluateJavaScript("reader.visibleText()") as? String
            }
            model.captureSelection = { [weak self] in await self?.captureSelection() }
            model.speechParagraphs = { [weak self] restart in
                guard let self, let webView = self.webView,
                      let result = try? await webView.callAsyncJavaScript("return reader.speechParagraphs(r, 20)",
                                                                          arguments: ["r": restart], contentWorld: .page),
                      let items = result as? [[String: Any]] else { return [] }
                return items.compactMap { item in
                    guard let id = (item["id"] as? NSNumber)?.intValue, let text = item["text"] as? String else { return nil }
                    return (text, id)
                }
            }
            model.speechHighlight = { [weak self] id, range in
                if let range {
                    self?.call("reader.speechHighlight(i, s, l)", ["i": id, "s": range.location, "l": range.length])
                } else {
                    self?.call("reader.speechClear()")
                }
            }
            model.readingAloudChanged = { [weak self] on in self?.call("reader.setReadingAloud(on)", ["on": on]) }
            if model.isReadingAloud { call("reader.setReadingAloud(on)", ["on": true]) }
            model.clearSelection = { [weak self] in self?.call("reader.clearSelection()") }
            model.revealHighlight = { [weak self] highlight in
                guard let self, case .text(let chapter, _, _, _, _) = highlight.location else { return }
                Task {
                    if !(await self.isLoaded(chapter)) { await self.replace(with: chapter, progress: 0) }
                    self.call("reader.reveal(id)", ["id": highlight.id.uuidString])
                }
            }
            model.reloadChapter = { [weak self] chapter in
                guard let self else { return }
                Task {
                    guard await self.isLoaded(chapter) else { return }
                    await self.replace(with: chapter, progress: self.model.currentPage == chapter ? self.model.pageProgress : 0)
                }
            }
            model.findQuote = { [weak self] quote, chapter in
                guard let self else { return false }
                if !(await self.isLoaded(chapter)) { await self.replace(with: chapter, progress: 0) }
                let found = try? await self.webView?.callAsyncJavaScript(
                    "return reader.revealQuote(chapter, exact, prefix, suffix)",
                    arguments: ["chapter": chapter, "exact": quote.exact, "prefix": quote.prefix, "suffix": quote.suffix],
                    contentWorld: .page) as? Bool
                return found == true
            }
        }

        func uninstall() {
            model.jumpToPage = nil
            model.jumpToPosition = nil
            model.turnPage = nil
            model.speechParagraphs = nil
            model.speechHighlight = nil
            model.readingAloudChanged = nil
            model.visibleText = nil
            model.captureSelection = nil
            model.clearSelection = nil
            model.revealHighlight = nil
            model.findQuote = nil
            model.reloadChapter = nil
        }

        // MARK: Loading

        /// The shell lives inside the book's content directory so chapters' relative resources resolve.
        func loadShell() {
            let shell = book.contentRoot.appending(path: ".scriptorium-shell.html")
            try? Self.shellHTML(layout: layout).write(to: shell, atomically: true, encoding: .utf8)
            webView?.loadFileURL(shell, allowingReadAccessTo: book.contentRoot)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !ready else { return }
            ready = true
            Task {
                _ = try? await webView.callAsyncJavaScript(
                    "reader.configure({layout: layout, total: total, scale: scale})",
                    arguments: ["layout": layout.rawValue, "total": book.pageCount, "scale": fontScale],
                    contentWorld: .page)
                await replace(with: model.currentPage, progress: model.startProgress)
                syncedHighlights = []
                sync(highlights: model.highlights)
                repaginate()
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Reload after a web content crash (memory pressure on a huge book), keeping the position.
            ready = false
            model.startProgress = model.pageProgress
            loadShell()
        }

        private func chapterArguments(_ index: Int) -> [String: Any]? {
            Self.chapterArguments(book: book, index: index, highlights: jsHighlights(chapter: index))
        }

        static func chapterArguments(book: ReflowableSource, index: Int, highlights: [[String: Any]]) -> [String: Any]? {
            let url = book.chapterURL(at: index)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return ["index": index, "text": text, "base": url.absoluteString, "hls": highlights]
        }

        private func insert(_ index: Int, where position: String) async {
            guard index >= 0, index < book.pageCount, !loading.contains(index),
                  var args = chapterArguments(index), let webView else { return }
            loading.insert(index)
            defer { loading.remove(index) }
            args["where"] = position
            _ = try? await webView.callAsyncJavaScript("reader.insert(index, text, base, where, hls)",
                                                       arguments: args, contentWorld: .page)
        }

        private func replace(with chapter: Int, progress: Double, fragment: String? = nil) async {
            await insert(chapter, where: "replace")
            _ = try? await webView?.callAsyncJavaScript("reader.goTo(c, p, f)",
                                                        arguments: ["c": chapter, "p": progress, "f": fragment ?? NSNull()],
                                                        contentWorld: .page)
        }

        private func isLoaded(_ chapter: Int) async -> Bool {
            let result = try? await webView?.callAsyncJavaScript("return reader.isLoaded(c)", arguments: ["c": chapter],
                                                                 contentWorld: .page)
            return result as? Bool ?? false
        }

        func go(to chapter: Int, progress: Double, fragment: String?) {
            let chapter = min(max(0, chapter), book.pageCount - 1)
            Task {
                let moved = try? await webView?.callAsyncJavaScript(
                    "return reader.goTo(c, p, f)", arguments: ["c": chapter, "p": progress, "f": fragment ?? NSNull()],
                    contentWorld: .page)
                if (moved as? Bool) != true { await replace(with: chapter, progress: progress, fragment: fragment) }
            }
        }

        func call(_ script: String, _ arguments: [String: Any] = [:]) {
            guard ready, let webView else { return }
            Task { _ = try? await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page) }
        }

        // MARK: Highlights

        private func jsHighlights(chapter: Int? = nil) -> [[String: Any]] {
            model.highlights.compactMap { h in
                guard case .text(let c, let start, let end, let prefix, let suffix) = h.location,
                      chapter == nil || chapter == c else { return nil }
                return ["id": h.id.uuidString, "chapter": c, "start": start, "end": end, "text": h.text,
                        "prefix": prefix, "suffix": suffix, "color": h.color.css]
            }
        }

        func sync(highlights: [Highlight]) {
            guard ready, highlights != syncedHighlights else { return }
            syncedHighlights = highlights
            call("reader.setHighlights(all)", ["all": jsHighlights()])
        }

        private func captureSelection() async -> (Highlight.Location, String)? {
            guard let result = try? await webView?.callAsyncJavaScript("return reader.captureSelection()",
                                                                        arguments: [:], contentWorld: .page),
                  let dict = result as? [String: Any],
                  let chapter = (dict["chapter"] as? NSNumber)?.intValue,
                  let start = (dict["start"] as? NSNumber)?.intValue,
                  let end = (dict["end"] as? NSNumber)?.intValue,
                  let text = dict["text"] as? String else { return nil }
            let location = Highlight.Location.text(chapter: chapter, start: start, end: end,
                                                   prefix: dict["prefix"] as? String ?? "",
                                                   suffix: dict["suffix"] as? String ?? "")
            return (location, text)
        }

        /// Previous/next screen in paged layout (keyboard on the Mac).
        func turnPage(_ delta: Int) {
            call("reader.turnPage(d)", ["d": delta])
        }

        // MARK: Long-press on links
        #if os(iOS)
        func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                     completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void) {
            guard let url = elementInfo.linkURL else { return completionHandler(nil) }
            Task { [weak self] in
                // The link's own text makes a better Read Later title than its URL.
                let title = try? await webView.callAsyncJavaScript(
                    "return [...document.links].find(a => a.href === u)?.innerText ?? null",
                    arguments: ["u": url.absoluteString], contentWorld: .page) as? String
                let external = !url.isFileURL
                completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                    var actions: [UIMenuElement] = []
                    if external {
                        actions.append(UIAction(title: "Add to Read Later", image: UIImage(systemName: "text.badge.plus")) { _ in
                            self?.model.addToReadLater(url: url, title: title)
                        })
                    }
                    actions.append(UIAction(title: "Open", image: UIImage(systemName: external ? "safari" : "arrow.right")) { _ in
                        if external {
                            UIApplication.shared.open(url)
                        } else if let self, let chapter = self.book.chapterIndex(for: url) {
                            self.model.pushCurrentPosition()
                            self.go(to: chapter, progress: 0, fragment: url.fragment)
                        }
                    })
                    if external {
                        actions.append(UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                            UIPasteboard.general.url = url
                        })
                    }
                    if TaskAppSender.isAvailable, let model = self?.model {
                        actions.append(UIAction(title: "Send Link to \(TaskAppLink.appName)", image: UIImage(systemName: "checklist")) { _ in
                            TaskAppSender.sendLink(url, title: title, from: model)
                        })
                    }
                    return UIMenu(title: title ?? url.absoluteString, children: actions)
                })
            }
        }
        #endif

        // MARK: Messages from the page

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let kind = body["type"] as? String else { return }
            switch kind {
            case "position":
                guard let chapter = (body["chapter"] as? NSNumber)?.intValue else { return }
                if model.currentPage != chapter { model.currentPage = chapter }
                model.pageProgress = (body["progress"] as? NSNumber)?.doubleValue ?? 0
                let page = (body["page"] as? NSNumber)?.intValue ?? 0, pages = (body["pages"] as? NSNumber)?.intValue ?? 0
                model.subPage = pages > 0 ? SubPage(page: page, pages: pages) : nil
            case "need":
                guard let chapter = (body["chapter"] as? NSNumber)?.intValue, let position = body["where"] as? String else { return }
                Task { await insert(chapter, where: position) }
            case "selection":
                model.selection = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            case "speakFrom":
                if let id = (body["id"] as? NSNumber)?.intValue, let offset = (body["offset"] as? NSNumber)?.intValue {
                    model.readAloud(fromAnchor: id, offset: offset)
                }
            case "tapHighlight":
                if let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)),
                   let highlight = model.highlights.first(where: { $0.id == id }) {
                    model.tappedHighlight = highlight
                }
            case "contextLink":
                #if os(macOS)
                lastContextLink = (body["href"] as? String).flatMap(URL.init(string:))
                #endif
            case "link":
                guard let href = body["href"] as? String, let url = URL(string: href) else { return }
                if url.isFileURL {
                    if let chapter = book.chapterIndex(for: url) {
                        model.pushCurrentPosition()
                        go(to: chapter, progress: 0, fragment: url.fragment)
                    }
                } else {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    UIApplication.shared.open(url)
                    #endif
                }
            default:
                break
            }
        }

        // MARK: Shell page

        static func shellHTML(layout: ReflowLayout) -> String {
            """
            <!DOCTYPE html>
            <html class="\(layout.rawValue)"><head><meta charset="utf-8"/>
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"/>
            <style id="reader-style">\(css)</style></head>
            <body><div id="book"></div></body></html>
            """
        }

        static let css = """
        :root { color-scheme: light dark; --scale: 1; --cols: 1; --ph: 44px; --pv: 40px;
                --bg: #fffdf8; --fg: #1d1b18; --link: #2f5fb3; }
        @media (prefers-color-scheme: dark) { :root { --bg: #1c1b1a; --fg: #e9e5dc; --link: #8fb4ff; } }
        /* Dark mode: books and saved web pages often hard-code dark text (and light boxes); use the reader's
           colours so nothing ends up dark on dark. Highlights (mark) and images keep theirs. */
        @media (prefers-color-scheme: dark) {
          .rchap, .rchap *:not(mark):not(img):not(svg):not(svg *) { color: var(--fg) !important;
            background-color: transparent !important; border-color: rgba(233, 229, 220, 0.25) !important; }
          html .rchap a[href], html .rchap a[href] *:not(img) { color: var(--link) !important; }
        }
        @media (max-width: 560px) { :root { --ph: 20px; --pv: 22px; } html { font-size: calc(18px * var(--scale)) !important; }
                                    html.scroll .rchap { padding: 18px 18px 8px; } }
        html { -webkit-text-size-adjust: none; font-size: calc(20px * var(--scale)) !important; background: var(--bg) !important; }
        body { margin: 0 !important; padding: 0 !important; max-width: none !important; background: var(--bg) !important;
               color: var(--fg) !important; font-family: -apple-system-ui-serif, ui-serif, Georgia, serif; line-height: 1.55;
               -webkit-tap-highlight-color: transparent; }
        .rchap * { font-size: inherit; }
        .rchap h1 { font-size: 1.6em !important; } .rchap h2 { font-size: 1.4em !important; }
        .rchap h3 { font-size: 1.25em !important; } .rchap h4, .rchap h5 { font-size: 1.1em !important; }
        .rchap h1, .rchap h2, .rchap h3, .rchap h4, .rchap h5, .rchap h6 { line-height: 1.25; }
        .rchap p { text-align: justify; hyphens: auto; -webkit-hyphens: auto; margin: 0 0 0.6em; }
        .rchap a { color: var(--link); }
        .rchap img, .rchap svg { max-width: 100% !important; height: auto !important; }
        .rchap .epigraph { font-style: italic; margin: 1em 0 1.5em 30%; }
        .rchap .poem { margin: 1em 0 1em 2em; } .rchap .stanza { text-align: left; }
        .rchap .author { text-align: right; font-style: italic; } .rchap p.image { text-align: center; }
        .rchap sup { font-size: 0.7em !important; }
        mark.rhl { background: var(--hl); color: inherit; border-radius: 2px; }
        ::highlight(speech) { background-color: rgba(70, 130, 255, 0.28); }

        html.paged { height: 100vh; overflow-y: hidden; }
        html.paged body { height: 100vh; column-width: calc(100vw / var(--cols)); column-gap: 0; column-fill: auto; }
        html.paged .rchap { break-before: column; box-sizing: border-box; padding: var(--pv) var(--ph);
                            -webkit-box-decoration-break: clone; box-decoration-break: clone; }
        html.paged .rchap img, html.paged .rchap svg { max-height: calc(100vh - 2 * var(--pv) - 1.5em) !important;
                            width: auto; object-fit: contain; break-inside: avoid; }

        html.scroll .rchap { max-width: 38em; margin: 0 auto; padding: 28px 32px 8px; }
        html.scroll .rchap + .rchap { border-top: 1px solid rgba(127,127,127,.25); margin-top: 2.5em; padding-top: 2.5em; }
        html.scroll #book { padding-bottom: 40vh; }
        """
    }

    static let engine: String = {
        guard let url = Bundle.main.url(forResource: "ReflowEngine", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("ReflowEngine.js missing from the app bundle")
            return ""
        }
        return source
    }()
}

extension Highlight.Color {
    /// Translucent, so text stays readable in light and dark mode.
    var css: String {
        let (r, g, b) = rgb
        return "rgba(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)), 0.42)"
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the coordinator.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
