import PDFKit
import ReaderCore
import SwiftUI

/// PDFKit viewer for PDFs with a text layer: native selection, links, zoom.
struct PDFKitView: UIViewRepresentable {
    let model: ReaderModel
    var turning: PageTurning = .vertical

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> PDFView {
        let view = LinkTrackingPDFView()
        view.onLinkJump = { [weak model] fromPage in
            guard let model else { return }
            model.currentPage = fromPage
            model.pushCurrentPosition()
        }
        view.document = model.pdfDocument
        if turning == .horizontal {
            // Book-like: one page per screen, swipe left/right.
            view.displayMode = .singlePage
            view.displayDirection = .horizontal
            view.usePageViewController(true, withViewOptions: [UIPageViewController.OptionsKey.interPageSpacing: 16])
        } else {
            view.displayMode = .singlePageContinuous
            view.displayDirection = .vertical
        }
        view.autoScales = true
        view.pageShadowsEnabled = true
        if let page = model.pdfDocument?.page(at: model.currentPage) { view.go(to: page) }
        context.coordinator.attach(to: view)
        // Long-press on a web link → Add to Read Later / Open / Copy (text selection is unaffected elsewhere).
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.sync(highlights: model.highlights)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        let model: ReaderModel
        private var observers: [NSObjectProtocol] = []
        private weak var pdfView: PDFView?
        private var speechAnnotations: [PDFAnnotation] = []
        /// Annotations drawn for each highlight (in memory only — the PDF file is never modified).
        private var drawn: [UUID: [PDFAnnotation]] = [:]

        init(model: ReaderModel) { self.model = model }

        // MARK: Link menu

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let pdfView, let (url, title) = webLink(in: pdfView, at: location) else { return nil }
            let model = model
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(title: title ?? url.absoluteString, children: [
                    UIAction(title: "Add to Read Later", image: UIImage(systemName: "text.badge.plus")) { _ in
                        model.addToReadLater(url: url, title: title)
                    },
                    UIAction(title: "Open", image: UIImage(systemName: "safari")) { _ in UIApplication.shared.open(url) },
                    UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.url = url },
                ])
            }
        }

        /// The web link under a point: a link annotation, or a URL written as plain text in the word there.
        private func webLink(in view: PDFView, at location: CGPoint) -> (URL, String?)? {
            guard let page = view.page(for: location, nearest: false) else { return nil }
            let point = view.convert(location, to: page)
            if let annotation = page.annotation(at: point), annotation.type == "Link" {
                let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url
                guard let url, url.scheme?.hasPrefix("http") == true || url.scheme == "mailto" else { return nil }
                let text = page.selection(for: annotation.bounds)?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (url, text?.isEmpty == false ? text : nil)
            }
            // Plain-text URL: look at the "word" under the finger (PDFKit words stop at spaces, so a URL is one word).
            guard let word = page.selectionForWord(at: point)?.string, word.contains(".") else { return nil }
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(word.startIndex..., in: word)
            guard let match = detector?.firstMatch(in: word, range: range), let url = match.url,
                  url.scheme?.hasPrefix("http") == true else { return nil }
            return (url, nil)
        }

        func attach(to view: PDFView) {
            pdfView = view
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .PDFViewAnnotationHit, object: view, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let annotation = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
                          let id = annotation.userName.flatMap(UUID.init(uuidString:)),
                          let highlight = self.model.highlights.first(where: { $0.id == id }) else { return }
                    self.model.tappedHighlight = highlight
                }
            })
            observers.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, let page = view.currentPage, let doc = view.document else { return }
                    self.model.currentPage = doc.index(for: page)
                }
            })
            observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.model.selection = view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
            })
            model.jumpToPage = { [weak view] index in
                guard let view, let page = view.document?.page(at: index) else { return }
                view.go(to: page)
            }
            model.captureSelection = { [weak view] in
                guard let view, let selection = view.currentSelection, let doc = view.document,
                      let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { return nil }
                // One rect per line per page, so multi-line highlights hug the text.
                let rects = selection.selectionsByLine().flatMap { line in
                    line.pages.map { page in Highlight.PageRect(page: doc.index(for: page), rect: line.bounds(for: page)) }
                }
                return rects.isEmpty ? nil : (.pdf(rects: rects), text)
            }
            model.clearSelection = { [weak view] in view?.clearSelection() }
            let fixedLayoutHighlight = model.speechHighlight
            model.speechHighlight = { [weak self, weak view] page, range in
                fixedLayoutHighlight?(page, range)          // follows the page
                guard let self, let view else { return }
                self.speechAnnotations.forEach { $0.page?.removeAnnotation($0) }
                self.speechAnnotations = []
                guard let range, let pdfPage = view.document?.page(at: page),
                      let selection = pdfPage.selection(for: range) else { return }
                for line in selection.selectionsByLine() {
                    let mark = PDFAnnotation(bounds: line.bounds(for: pdfPage), forType: .highlight, withProperties: nil)
                    mark.color = UIColor(red: 0.27, green: 0.51, blue: 1, alpha: 0.3)
                    pdfPage.addAnnotation(mark)
                    self.speechAnnotations.append(mark)
                }
            }
            model.revealHighlight = { [weak view] highlight in
                guard let view, case .pdf(let rects) = highlight.location, let first = rects.first,
                      let page = view.document?.page(at: first.page) else { return }
                view.go(to: first.rect.insetBy(dx: 0, dy: -80), on: page)
            }
        }

        func sync(highlights: [Highlight]) {
            guard let doc = pdfView?.document else { return }
            let wanted = Dictionary(uniqueKeysWithValues: highlights.compactMap { h -> (UUID, Highlight)? in
                if case .pdf = h.location { return (h.id, h) }
                return nil
            })
            for (id, annotations) in drawn where wanted[id] == nil {
                for annotation in annotations { annotation.page?.removeAnnotation(annotation) }
                drawn[id] = nil
            }
            for (id, highlight) in wanted where drawn[id] == nil {
                guard case .pdf(let rects) = highlight.location else { continue }
                let (r, g, b) = highlight.color.rgb
                drawn[id] = rects.compactMap { item in
                    guard let page = doc.page(at: item.page) else { return nil }
                    let annotation = PDFAnnotation(bounds: item.rect, forType: .highlight, withProperties: nil)
                    annotation.color = UIColor(red: r, green: g, blue: b, alpha: 0.45)
                    annotation.userName = id.uuidString
                    page.addAnnotation(annotation)
                    return annotation
                }
            }
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            model.jumpToPage = nil
            model.captureSelection = nil
            model.clearSelection = nil
            model.revealHighlight = nil
        }
    }
}

/// PDFKit follows internal links (contents pages, footnotes, cross-references) on its own;
/// this reports each such jump with the page the reader was on, for the Back button.
final class LinkTrackingPDFView: PDFView {
    var onLinkJump: ((Int) -> Void)?

    override func go(to destination: PDFDestination) {
        // Only real jumps: broken links (no target page) must not leave a Back entry behind.
        if let page = currentPage, let target = destination.page, let document, target != page {
            onLinkJump?(document.index(for: page))
        }
        super.go(to: destination)
    }
}
