import ReaderCore
import UIKit
import WebKit

/// Counts how many pages each chapter of a reflowable book takes at the current size, font and layout,
/// using a hidden web view with the same engine. Results are cached per book/size/font/layout.
@MainActor
final class Paginator: NSObject, WKNavigationDelegate {
    private let book: ReflowableSource
    private let layout: ReflowLayout
    private var webView: WKWebView?
    private var task: Task<Void, Never>?
    private var shellLoaded: CheckedContinuation<Void, Never>?
    private(set) var key = ""
    var onMeasured: (_ chapter: Int, _ pages: Int) -> Void = { _, _ in }

    init(book: ReflowableSource, layout: ReflowLayout) {
        self.book = book
        self.layout = layout
    }

    /// (Re)measures for a viewport size and font scale; cached results are delivered immediately.
    func start(in host: UIView, size: CGSize, scale: Double) {
        guard size.width > 50, size.height > 50 else { return }
        let key = "\(book.url.lastPathComponent)|\(book.pageCount)|\(layout.rawValue)|\(scale)|\(Int(size.width))x\(Int(size.height))|v1"
        guard key != self.key else { return }
        self.key = key
        cancel()

        var cached = Self.cache[key] ?? [:]
        for (chapter, pages) in cached { onMeasured(chapter, pages) }
        guard cached.count < book.pageCount else { return }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: ReflowableView.engine, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(NullMessageHandler(), name: "reader")
        let view = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        view.alpha = 0.01                       // laid out and rendered, but not visible or touchable
        view.isUserInteractionEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.navigationDelegate = self
        host.insertSubview(view, at: 0)
        webView = view

        let shell = book.contentRoot.appending(path: ".scriptorium-measure.html")
        try? ReflowableView.Coordinator.shellHTML(layout: layout).write(to: shell, atomically: true, encoding: .utf8)

        task = Task { [weak self] in
            guard let self else { return }
            await withCheckedContinuation { continuation in
                self.shellLoaded = continuation
                view.loadFileURL(shell, allowingReadAccessTo: self.book.contentRoot)
            }
            _ = try? await view.callAsyncJavaScript("reader.configure({layout: l, total: t, scale: s})",
                                                    arguments: ["l": layout.rawValue, "t": book.pageCount, "s": scale],
                                                    contentWorld: .page)
            for chapter in 0..<book.pageCount where cached[chapter] == nil {
                if Task.isCancelled { return }
                guard var args = ReflowableView.Coordinator.chapterArguments(book: book, index: chapter, highlights: []) else { continue }
                args["where"] = "replace"
                _ = try? await view.callAsyncJavaScript("reader.insert(index, text, base, where, hls)",
                                                        arguments: args, contentWorld: .page)
                let result = try? await view.callAsyncJavaScript("return await reader.measure()", arguments: [:],
                                                                 contentWorld: .page)
                guard !Task.isCancelled, let pages = (result as? NSNumber)?.intValue, pages > 0 else { continue }
                cached[chapter] = pages
                Self.cache[key] = cached
                onMeasured(chapter, pages)
            }
            self.cancel()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        shellLoaded?.resume()
        shellLoaded = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        webView?.removeFromSuperview()
        webView = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        shellLoaded?.resume()
        shellLoaded = nil
    }

    // Small persistent cache: [key: [chapter: pages]].
    private static var cache: [String: [Int: Int]] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "pagination.v1"),
                  let stored = try? JSONDecoder().decode([String: [Int: Int]].self, from: data) else { return [:] }
            return stored
        }
        set {
            // Keep the 40 most recent layouts.
            var trimmed = newValue
            if trimmed.count > 40 { trimmed = Dictionary(uniqueKeysWithValues: trimmed.suffix(40).map { ($0.key, $0.value) }) }
            UserDefaults.standard.set(try? JSONEncoder().encode(trimmed), forKey: "pagination.v1")
        }
    }
}

private final class NullMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

/// Reports size changes (rotation, split view, inspector) so pagination can be redone.
final class ReaderWebView: WKWebView {
    var onSizeChange: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onSizeChange?(bounds.size)
        }
    }
}
