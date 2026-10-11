import ReaderCore
import SwiftUI
import UIKit

/// How fixed-layout documents (PDF, DjVu, scans) are navigated.
enum PageTurning: String, CaseIterable, Identifiable {
    case horizontal, vertical
    var id: String { rawValue }
    var title: String { self == .horizontal ? "Pages left to right" : "Vertical scroll" }
    var systemImage: String { self == .horizontal ? "book.pages" : "arrow.up.and.down.text.horizontal" }
}

/// Book-like horizontal paging for rendered pages (DjVu, scanned PDFs): one page per screen,
/// swipe left/right, each page zoomable on its own, Live Text selection and highlights preserved.
struct HorizontalPageView: UIViewControllerRepresentable {
    let model: ReaderModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                         options: [.interPageSpacing: 16])
        pager.view.backgroundColor = .secondarySystemBackground
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        context.coordinator.pager = pager
        context.coordinator.show(page: model.currentPage, animated: false)
        context.coordinator.install()
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.update(highlights: model.highlights)
    }

    static func dismantleUIViewController(_ pager: UIPageViewController, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        let model: ReaderModel
        weak var pager: UIPageViewController?
        private var highlights: [Highlight] = []
        private var selectionPage: Int?
        private var selectedText: String?
        /// Live page controllers (UIPageViewController keeps up to three).
        private let live = NSHashTable<ZoomablePageController>.weakObjects()

        init(model: ReaderModel) {
            self.model = model
            highlights = model.highlights
        }

        func install() {
            model.jumpToPage = { [weak self] page in self?.show(page: page, animated: false) }
            let text = model.text
            model.captureSelection = { [weak self] in
                guard let self, let page = self.selectionPage, let selected = self.selectedText, !selected.isEmpty,
                      let pageText = try? await text.text(page: page, allowOCR: true),
                      let rects = pageText.rects(matching: selected) else { return nil }
                return (.image(page: page, rects: rects), selected)
            }
            model.clearSelection = { [weak self] in
                self?.live.allObjects.forEach { $0.pageView.clearSelection() }
                self?.selectionPage = nil
                self?.selectedText = nil
            }
        }

        func uninstall() {
            model.jumpToPage = nil
            model.captureSelection = nil
            model.clearSelection = nil
        }

        func show(page: Int, animated: Bool) {
            guard let pager, (0..<model.source.pageCount).contains(page) else { return }
            let current = (pager.viewControllers?.first as? ZoomablePageController)?.index ?? page
            pager.setViewControllers([controller(for: page)], direction: page >= current ? .forward : .reverse,
                                     animated: animated)
            model.currentPage = page
        }

        func update(highlights: [Highlight]) {
            guard highlights != self.highlights else { return }
            self.highlights = highlights
            for controller in live.allObjects { controller.pageView.highlights = pageHighlights(controller.index) }
        }

        private func pageHighlights(_ page: Int) -> [Highlight] {
            highlights.filter { if case .image(let p, _) = $0.location { p == page } else { false } }
        }

        private func controller(for page: Int) -> ZoomablePageController {
            let controller = ZoomablePageController(source: model.source, index: page)
            controller.pageView.highlights = pageHighlights(page)
            controller.pageView.onSelectionChange = { [weak self] text in self?.selectionChanged(text, page: page) }
            live.add(controller)
            return controller
        }

        private func selectionChanged(_ text: String, page: Int) {
            if !text.isEmpty {
                selectionPage = page
                selectedText = text
            } else if selectionPage == page {
                selectionPage = nil
                selectedText = nil
            }
            model.selection = text
        }

        // MARK: UIPageViewControllerDataSource

        func pageViewController(_ pager: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let index = (viewController as? ZoomablePageController)?.index, index > 0 else { return nil }
            return controller(for: index - 1)
        }

        func pageViewController(_ pager: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let index = (viewController as? ZoomablePageController)?.index, index + 1 < model.source.pageCount else { return nil }
            return controller(for: index + 1)
        }

        func pageViewController(_ pager: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let index = (pager.viewControllers?.first as? ZoomablePageController)?.index else { return }
            model.currentPage = index
            if selectionPage != index { model.selection = "" }
        }
    }
}

/// One page, fitted to the screen, with its own pinch/double-tap zoom.
final class ZoomablePageController: UIViewController, UIScrollViewDelegate {
    let index: Int
    let pageView: PageImageView
    private let scrollView = UIScrollView()
    private let aspect: CGFloat

    init(source: PageSource, index: Int) {
        self.index = index
        pageView = PageImageView(source: source, index: index)
        let size = source.pageSize(at: index)
        aspect = size.width > 0 ? size.height / size.width : 1.3
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)
        scrollView.addSubview(pageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scrollView.zoomScale == 1 else { return }
        // Aspect-fit the page into the safe area.
        let area = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 12, dy: 12)
        var size = CGSize(width: area.width, height: area.width * aspect)
        if size.height > area.height { size = CGSize(width: area.height / aspect, height: area.height) }
        pageView.frame = CGRect(x: 0, y: 0, width: size.width.rounded(), height: size.height.rounded())
        scrollView.contentSize = pageView.frame.size
        centre()
        pageView.ensureResolution(pixelWidth: size.width * (view.window?.screen.scale ?? 2))
    }

    private func centre() {
        let dx = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let dy = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        pageView.ensureResolution(pixelWidth: pageView.bounds.width * scale * (self.view.window?.screen.scale ?? 2))
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: pageView)
            let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }
}
