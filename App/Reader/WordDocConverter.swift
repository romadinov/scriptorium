import ReaderCore
import UIKit
import WebKit
import os

private let log = Logger(subsystem: "com.romadinov.reader", category: "WordDoc")

/// Old binary Word files (`.doc`) have no parser on iOS, but WebKit renders them (through the system's
/// Office import). Load the file once in a hidden web view, take the resulting HTML — with images
/// inlined as data URLs — and save it where `DOCSource` picks it up.
@MainActor
final class WordDocConverter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var finished: CheckedContinuation<Void, Error>?

    static func convertIfNeeded(_ url: URL) async throws {
        guard DOCSource.canOpen(url), !DOCSource.isConverted(url) else { return }
        let html = try await WordDocConverter().html(of: url)
        try DOCSource.saveConverted(html: html, for: url)
    }

    private func html(of url: URL) async throws -> String {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        view.navigationDelegate = self
        webView = view
        defer { webView = nil }
        try await withCheckedThrowingContinuation { continuation in
            finished = continuation
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        // The converted document can still be laying out images; give it a moment.
        try await Task.sleep(for: .milliseconds(300))
        let script = """
        const imgs = [...document.images];
        await Promise.all(imgs.map((img) => img.complete ? null : new Promise((r) => { img.onload = img.onerror = r; })));
        for (const img of imgs) {
          if (img.src.startsWith('data:') || !img.naturalWidth) continue;
          try {
            const canvas = document.createElement('canvas');
            canvas.width = img.naturalWidth; canvas.height = img.naturalHeight;
            canvas.getContext('2d').drawImage(img, 0, 0);
            img.setAttribute('src', canvas.toDataURL('image/png'));
          } catch (e) {}
        }
        // Word headings come out as big bold paragraphs: measure the rendered sizes and make real headings
        // (≥1.6× the body size → h1, ≥1.2× → h2, short and all bold → h3) so chapters and contents work.
        const paras = [...document.querySelectorAll('p')].filter((p) => p.textContent.trim());
        const size = (el) => parseFloat(getComputedStyle(el).fontSize) || 0;
        const runs = (p) => [...p.querySelectorAll('span')].filter((s) => s.textContent.trim() && !s.querySelector('span'));
        const weight = new Map();
        for (const p of paras) for (const s of runs(p)) {
          const k = Math.round(size(s));
          weight.set(k, (weight.get(k) || 0) + s.textContent.length);
        }
        const body = [...weight.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] || 16;
        for (const p of paras) {
          const text = p.textContent.trim();
          const spans = runs(p);
          if (!spans.length || text.length > 120 || p.closest('td')) continue;
          const min = Math.min(...spans.map(size));
          const bold = spans.every((s) => parseInt(getComputedStyle(s).fontWeight) >= 600);
          const level = min >= body * 1.6 ? 1 : min >= body * 1.2 ? 2 : (bold && !/[.:]$/.test(text) ? 3 : 0);
          if (!level) continue;
          const h = document.createElement('h' + level);
          h.innerHTML = p.innerHTML;
          p.replaceWith(h);
        }
        return document.documentElement.outerHTML;
        """
        let result = try await view.callAsyncJavaScript(script, arguments: [:], contentWorld: .page)
        guard let html = result as? String, html.count > 40 else { throw DocumentError.cannotOpen(url) }
        log.debug("Converted \(url.lastPathComponent, privacy: .public): \(html.count) characters")
        return html
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finished?.resume(throwing: error)
        finished = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finished?.resume(throwing: error)
        finished = nil
    }
}
