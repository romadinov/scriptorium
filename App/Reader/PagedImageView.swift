import ReaderCore
import SwiftUI
import UIKit
import VisionKit
import os

private let log = Logger(subsystem: "com.romadinov.reader", category: "LiveText")

/// Continuous vertical viewer that renders pages to images (DjVu, scanned PDFs).
/// Text selection comes from VisionKit Live Text on each visible page.
struct PagedImageView: UIViewRepresentable {
    let model: ReaderModel

    func makeUIView(context: Context) -> PagedImageScrollView {
        let view = PagedImageScrollView(source: model.source, initialPage: model.currentPage)
        view.onPageChange = { [weak model] page in model?.currentPage = page }
        view.onSelectionChange = { [weak model] text in model?.selection = text }
        view.canReadFromTap = { [weak model] in model?.isReadingAloud ?? false }
        view.readFromTap = { [weak model] page, point in model?.readAloud(fromPage: page, normalizedPoint: point) }
        model.jumpToPage = { [weak view] page in view?.scroll(to: page, animated: false) }
        let text = model.text
        model.captureSelection = { [weak view] in
            // VisionKit doesn't expose selection geometry; find the selected words in the page's text layer.
            guard let view, let page = view.selectionPage, let selected = view.selectedText, !selected.isEmpty,
                  let pageText = try? await text.text(page: page, allowOCR: true),
                  let rects = pageText.rects(matching: selected) else { return nil }
            return (.image(page: page, rects: rects), selected)
        }
        model.clearSelection = { [weak view] in view?.clearSelections() }
        return view
    }

    func updateUIView(_ view: PagedImageScrollView, context: Context) {
        view.highlights = model.highlights
    }

}

final class PagedImageScrollView: UIScrollView, UIScrollViewDelegate {
    var onPageChange: ((Int) -> Void)?
    var onSelectionChange: ((String) -> Void)?
    var canReadFromTap: (() -> Bool)?
    var readFromTap: ((Int, CGPoint) -> Void)?
    private(set) var selectionPage: Int?
    private(set) var selectedText: String?
    var highlights: [Highlight] = [] {
        didSet { if highlights != oldValue { for (index, view) in pageViews { view.highlights = highlightsByPage[index] ?? [] } } }
    }
    private var highlightsByPage: [Int: [Highlight]] {
        Dictionary(grouping: highlights.filter { if case .image = $0.location { true } else { false } },
                   by: { $0.location.pageIndex })
    }

    private let source: PageSource
    private let content = UIView()
    private var frames: [CGRect] = []
    private var pageViews: [Int: PageImageView] = [:]
    private var laidOutWidth: CGFloat = 0
    private var pendingPage: Int?
    private var reportedPage = -1
    private let spacing: CGFloat = 12
    /// Page aspect ratios, read once — DjVu page info is cheap but not free.
    private lazy var aspects: [CGFloat] = (0..<source.pageCount).map { index in
        let size = source.pageSize(at: index)
        return size.width > 0 ? size.height / size.width : 1.3
    }

    init(source: PageSource, initialPage: Int) {
        self.source = source
        pendingPage = initialPage
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .secondarySystemBackground
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .always
        addSubview(content)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        if width > 0, abs(width - laidOutWidth) > 1 {
            let keepPage = pendingPage ?? currentPage()
            relayout(width: width)
            pendingPage = nil
            scroll(to: keepPage, animated: false)
        }
        updateVisiblePages()
    }

    private func relayout(width: CGFloat) {
        laidOutWidth = width
        setZoomScale(1, animated: false)
        let pageWidth = width - spacing * 2
        var y = spacing
        frames = aspects.map { aspect in
            let frame = CGRect(x: spacing, y: y, width: pageWidth, height: (pageWidth * aspect).rounded())
            y = frame.maxY + spacing
            return frame
        }
        content.frame = CGRect(x: 0, y: 0, width: width, height: y)
        contentSize = content.frame.size
        for (index, view) in pageViews { view.frame = frames[index] }
    }

    func scroll(to page: Int, animated: Bool) {
        guard frames.indices.contains(page) else {
            pendingPage = page
            return
        }
        let y = frames[page].minY * zoomScale - spacing - adjustedContentInset.top
        let maxY = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        setContentOffset(CGPoint(x: contentOffset.x, y: min(max(-adjustedContentInset.top, y), maxY)), animated: animated)
        updateVisiblePages()
    }

    private func currentPage() -> Int {
        guard !frames.isEmpty else { return 0 }
        let probe = (contentOffset.y + adjustedContentInset.top + bounds.height * 0.35) / zoomScale
        return frames.firstIndex { $0.maxY + spacing >= probe } ?? frames.count - 1
    }

    // MARK: Page views

    private func updateVisiblePages() {
        guard !frames.isEmpty else { return }
        let visible = CGRect(x: contentOffset.x / zoomScale, y: contentOffset.y / zoomScale,
                             width: bounds.width / zoomScale, height: bounds.height / zoomScale)
        let keep = visible.insetBy(dx: 0, dy: -visible.height)         // one screen above and below
        let wanted = Set(frames.indices.filter { frames[$0].intersects(keep) })

        for (index, view) in pageViews where !wanted.contains(index) {
            view.removeFromSuperview()
            pageViews[index] = nil
        }
        let pixelScale = window?.screen.scale ?? 2
        for index in wanted.sorted() {
            let view = pageViews[index] ?? {
                let view = PageImageView(source: source, index: index)
                view.onSelectionChange = { [weak self] text in self?.selectionChanged(text, on: index) }
                view.canReadFromTap = { [weak self] in self?.canReadFromTap?() ?? false }
                view.readFromTap = { [weak self] page, point in self?.readFromTap?(page, point) }
                view.highlights = highlightsByPage[index] ?? []
                content.addSubview(view)
                pageViews[index] = view
                return view
            }()
            view.frame = frames[index]
            view.ensureResolution(pixelWidth: frames[index].width * pixelScale * zoomScale)
        }

        let page = currentPage()
        if page != reportedPage {
            reportedPage = page
            onPageChange?(page)
        }
    }

    private func selectionChanged(_ text: String, on page: Int) {
        if !text.isEmpty {
            for (index, view) in pageViews where index != page { view.clearSelection() }
            selectionPage = page
            selectedText = text
        } else if selectionPage == page {
            selectionPage = nil
            selectedText = nil
        }
        onSelectionChange?(text)
    }

    func clearSelections() {
        for view in pageViews.values { view.clearSelection() }
        selectionPage = nil
        selectedText = nil
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisiblePages() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateVisiblePages()
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: content)
            zoom(to: CGRect(x: point.x - bounds.width / 4, y: point.y - bounds.height / 4,
                            width: bounds.width / 2, height: bounds.height / 2), animated: true)
        }
    }
}

/// One rendered page with a Live Text interaction attached.
final class PageImageView: UIImageView, ImageAnalysisInteractionDelegate, UIGestureRecognizerDelegate {
    var onSelectionChange: ((String) -> Void)?
    /// While reading aloud, a tap on a word continues from there (page index, point normalised to the page).
    var canReadFromTap: (() -> Bool)?
    var readFromTap: ((Int, CGPoint) -> Void)?
    var highlights: [Highlight] = [] {
        didSet { if highlights != oldValue { setNeedsLayout() } }
    }
    private var highlightLayers: [CALayer] = []

    private static let analyzer = ImageAnalyzer()
    private let source: PageSource
    private let index: Int
    private let interaction = ImageAnalysisInteraction()
    private var renderedWidth: CGFloat = 0
    private var task: Task<Void, Never>?

    init(source: PageSource, index: Int) {
        self.source = source
        self.index = index
        super.init(frame: .zero)
        backgroundColor = .white
        contentMode = .scaleToFill
        isUserInteractionEnabled = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        interaction.delegate = self
        addInteraction(interaction)
        isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedWhileReading(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { task?.cancel() }

    /// Renders (or re-renders after zooming in) when the on-screen pixel width outgrows the image.
    func ensureResolution(pixelWidth: CGFloat) {
        let target = min(pixelWidth, 4096).rounded()
        guard target > renderedWidth * 1.25 else { return }
        renderedWidth = target
        let aspect = bounds.width > 0 ? bounds.height / bounds.width : 1.3
        let maxPixel = Int(max(target, target * aspect))
        let source = source, index = index

        task?.cancel()
        task = Task { [weak self] in
            let cg = await Task.detached(priority: .userInitiated) {
                try? source.renderPage(at: index, maxPixelSize: maxPixel)
            }.value
            guard let self, let cg, !Task.isCancelled else { return }
            let image = UIImage(cgImage: cg)
            self.image = image
            // Live Text analysis is the expensive part. Run it once per page (the result is in page
            // coordinates, so a sharper re-render after zooming keeps it), and only for pages the reader
            // stays on, not every page flicked past.
            guard !self.analyzed else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self.analyze(image)
        }
    }

    func clearSelection() {
        interaction.resetTextSelection()
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture.view === self, gesture is UITapGestureRecognizer, gesture.delegate === self else {
            return super.gestureRecognizerShouldBegin(gesture)
        }
        return canReadFromTap?() ?? false
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func tappedWhileReading(_ gesture: UITapGestureRecognizer) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = gesture.location(in: self)
        readFromTap?(index, CGPoint(x: point.x / bounds.width, y: point.y / bounds.height))
    }

    /// Highlight rects are normalised to the page, so they follow zoom and rotation via layout.
    override func layoutSubviews() {
        super.layoutSubviews()
        highlightLayers.forEach { $0.removeFromSuperlayer() }
        highlightLayers = highlights.flatMap { highlight -> [CALayer] in
            guard case .image(_, let rects) = highlight.location else { return [] }
            let (r, g, b) = highlight.color.rgb
            return rects.map { rect in
                let layer = CALayer()
                layer.frame = CGRect(x: rect.minX * bounds.width - 2, y: rect.minY * bounds.height - 1,
                                     width: rect.width * bounds.width + 4, height: rect.height * bounds.height + 2)
                layer.backgroundColor = UIColor(red: r, green: g, blue: b, alpha: 1).cgColor
                layer.compositingFilter = "multiplyBlendMode"   // ink stays dark, paper turns the highlight colour
                layer.cornerRadius = 2
                return layer
            }
        }
        highlightLayers.forEach(layer.addSublayer)
    }

    private var analyzed = false

    private func analyze(_ image: UIImage) async {
        guard ImageAnalyzer.isSupported else {
            log.error("ImageAnalyzer not supported on this device; Live Text selection disabled")
            return
        }
        let configuration = ImageAnalyzer.Configuration([.text])
        let analysis: ImageAnalysis
        do {
            analysis = try await Self.analyzer.analyze(image, orientation: .up, configuration: configuration)
        } catch {
            log.error("Live Text analysis failed for page \(self.index): \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }
        log.debug("Live Text ready for page \(self.index), hasText=\(analysis.hasResults(for: .text))")
        interaction.analysis = analysis
        analyzed = true
        // Must be set after the analysis, or the interaction ignores touches.
        interaction.preferredInteractionTypes = .textSelection
        // The app's own selection bar replaces VisionKit's corner Live Text button.
        interaction.isSupplementaryInterfaceHidden = true
    }

    // MARK: ImageAnalysisInteractionDelegate

    func textSelectionDidChange(_ interaction: ImageAnalysisInteraction) {
        onSelectionChange?(interaction.selectedText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
