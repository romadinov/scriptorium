import ReaderCore
import SwiftUI
import VisionKit
import os

private let log = Logger(subsystem: "com.romadinov.reader", category: "LiveText")

/// Continuous vertical viewer for pages rendered to images (DjVu, scanned PDFs), with Live Text selection.
struct MacImagePagesView: NSViewRepresentable {
    let model: ReaderModel
    var contextMenu: ((NSMenu) -> Void)?

    func makeNSView(context: Context) -> PageScrollView {
        let view = PageScrollView(source: model.source, initialPage: model.currentPage)
        view.onPageChange = { [weak model] page in model?.currentPage = page }
        view.onSelectionChange = { [weak model] text in model?.selection = text }
        view.canReadFromClick = { [weak model] in model?.isReadingAloud ?? false }
        view.readFromClick = { [weak model] page, point in model?.readAloud(fromPage: page, normalizedPoint: point) }
        model.jumpToPage = { [weak view] page in view?.scroll(to: page) }
        let text = model.text
        model.captureSelection = { [weak view] in
            // VisionKit doesn't expose selection geometry; find the selected words in the page's text layer.
            guard let view, let page = view.selectionPage, let selected = view.selectedText, !selected.isEmpty,
                  let rects = await text.rects(matching: selected, page: page) else { return nil }
            return (.image(page: page, rects: rects), selected)
        }
        model.clearSelection = { [weak view] in view?.clearSelections() }
        model.revealHighlight = { [weak view] highlight in
            guard case .image(let page, _) = highlight.location else { return }
            view?.scroll(to: page)
        }
        return view
    }

    func updateNSView(_ view: PageScrollView, context: Context) {
        view.contextMenu = contextMenu
        view.highlights = model.highlights
    }

    static func dismantleNSView(_ view: PageScrollView, coordinator: ()) {}
}

final class PageScrollView: NSScrollView {
    var onPageChange: ((Int) -> Void)?
    var onSelectionChange: ((String) -> Void)?
    var canReadFromClick: (() -> Bool)?
    var readFromClick: ((Int, CGPoint) -> Void)?
    var contextMenu: ((NSMenu) -> Void)?
    var highlights: [Highlight] = [] {
        didSet {
            guard highlights != oldValue else { return }
            for (index, view) in pageViews { view.highlights = highlights.filter { $0.location.pageIndex == index && isImage($0) } }
        }
    }
    private(set) var selectionPage: Int?
    private(set) var selectedText: String?

    private let source: PageSource
    private let content = FlippedView()
    private var frames: [CGRect] = []
    private var pageViews: [Int: MacPageImageView] = [:]
    private var pendingPage: Int?
    private var reportedPage = -1
    private let spacing: CGFloat = 16

    init(source: PageSource, initialPage: Int) {
        self.source = source
        pendingPage = initialPage
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.5
        maxMagnification = 4
        drawsBackground = true
        backgroundColor = .underPageBackgroundColor
        documentView = content
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func isImage(_ h: Highlight) -> Bool { if case .image = h.location { true } else { false } }

    override func layout() {
        super.layout()
        layoutPages()
    }

    /// Pages as wide as the window (up to a readable width), stacked vertically.
    private func layoutPages() {
        let width = contentView.bounds.width / magnification
        guard width > 50 else { return }
        let pageWidth = min(width - 2 * spacing, 1100)
        var y = spacing
        frames = (0..<source.pageCount).map { index in
            let size = source.pageSize(at: index)
            let aspect = size.width > 0 ? size.height / size.width : 1.3
            let frame = CGRect(x: (width - pageWidth) / 2, y: y, width: pageWidth, height: pageWidth * aspect)
            y += frame.height + spacing
            return frame
        }
        content.frame = CGRect(x: 0, y: 0, width: width, height: y)
        if let page = pendingPage, frames.indices.contains(page) {
            pendingPage = nil
            contentView.scroll(to: CGPoint(x: 0, y: frames[page].minY - spacing))
            reflectScrolledClipView(contentView)
        }
        updateVisiblePages()
    }

    func scroll(to page: Int) {
        guard frames.indices.contains(page) else { pendingPage = page; return }
        contentView.scroll(to: CGPoint(x: contentView.bounds.minX, y: frames[page].minY - spacing))
        reflectScrolledClipView(contentView)
        updateVisiblePages()
    }

    @objc private func scrolled() { updateVisiblePages() }
    @objc private func magnified() { updateVisiblePages() }

    private func updateVisiblePages() {
        guard !frames.isEmpty else { return }
        let visible = contentView.bounds
        let keep = visible.insetBy(dx: 0, dy: -visible.height)
        let wanted = Set(frames.indices.filter { frames[$0].intersects(keep) })
        for (index, view) in pageViews where !wanted.contains(index) {
            view.removeFromSuperview()
            pageViews[index] = nil
        }
        let scale = (window?.backingScaleFactor ?? 2) * magnification
        for index in wanted.sorted() {
            let view = pageViews[index] ?? {
                let view = MacPageImageView(source: source, index: index)
                view.onSelectionChange = { [weak self] text in self?.selectionChanged(text, on: index) }
                view.canReadFromClick = { [weak self] in self?.canReadFromClick?() ?? false }
                view.readFromClick = { [weak self] page, point in self?.readFromClick?(page, point) }
                view.extendMenu = { [weak self] menu in self?.contextMenu?(menu) }
                view.highlights = highlights.filter { $0.location.pageIndex == index && isImage($0) }
                content.addSubview(view)
                pageViews[index] = view
                return view
            }()
            view.frame = frames[index]
            view.ensureResolution(pixelWidth: frames[index].width * scale)
        }
        // Current page: the one under a point a third of the way down the screen.
        let probe = visible.minY + visible.height / 3
        let page = frames.firstIndex { $0.maxY >= probe } ?? frames.count - 1
        if page != reportedPage {
            reportedPage = page
            onPageChange?(page)
        }
    }

    private func selectionChanged(_ text: String, on page: Int) {
        if text.isEmpty {
            guard selectionPage == page else { return }
            selectionPage = nil
            selectedText = nil
        } else {
            for (index, view) in pageViews where index != page { view.clearSelection() }
            selectionPage = page
            selectedText = text
        }
        onSelectionChange?(text)
    }

    func clearSelections() {
        pageViews.values.forEach { $0.clearSelection() }
        selectionPage = nil
        selectedText = nil
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One rendered page with a Live Text overlay.
final class MacPageImageView: NSImageView, ImageAnalysisOverlayViewDelegate {
    var onSelectionChange: ((String) -> Void)?
    var canReadFromClick: (() -> Bool)?
    var readFromClick: ((Int, CGPoint) -> Void)?
    var extendMenu: ((NSMenu) -> Void)?
    var highlights: [Highlight] = [] { didSet { if highlights != oldValue { needsLayout = true } } }

    private static let analyzer = ImageAnalyzer()
    private let source: PageSource
    private let index: Int
    private let overlay = ImageAnalysisOverlayView()
    private var renderedWidth: CGFloat = 0
    private var task: Task<Void, Never>?
    private var highlightLayers: [CALayer] = []

    init(source: PageSource, index: Int) {
        self.source = source
        self.index = index
        super.init(frame: .zero)
        imageScaling = .scaleAxesIndependently
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.shadowOpacity = 0.15
        layer?.shadowRadius = 3
        overlay.delegate = self
        overlay.trackingImageView = self
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { task?.cancel() }

    override var isFlipped: Bool { true }

    func ensureResolution(pixelWidth: CGFloat) {
        let target = min(pixelWidth, 5000).rounded()
        guard target > renderedWidth * 1.25 else { return }
        renderedWidth = target
        let aspect = bounds.width > 0 ? bounds.height / bounds.width : 1.3
        let maxPixel = Int(max(target, target * aspect))
        let source = source, index = index
        task?.cancel()
        task = Task { [weak self] in
            let cg = await Task.detached(priority: .userInitiated) { try? source.renderPage(at: index, maxPixelSize: maxPixel) }.value
            guard let self, let cg, !Task.isCancelled else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            self.image = image
            self.overlay.setContentsRectNeedsUpdate()
            // Analyse only pages the reader stays on, and not again while the overlay still has an analysis.
            guard self.overlay.analysis == nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self.analyze(image)
        }
    }

    private func analyze(_ image: NSImage) async {
        guard ImageAnalyzer.isSupported else { return }
        do {
            let analysis = try await Self.analyzer.analyze(image, orientation: .up, configuration: .init([.text]))
            guard !Task.isCancelled else { return }
            overlay.analysis = analysis
            overlay.preferredInteractionTypes = .textSelection
            overlay.isSupplementaryInterfaceHidden = true      // the reader's own menus replace the Live Text button
            overlay.setContentsRectNeedsUpdate()
        } catch {
            log.error("Live Text analysis failed for page \(self.index): \(error.localizedDescription)")
        }
    }

    func clearSelection() { overlay.resetSelection() }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        overlay.setContentsRectNeedsUpdate()
        highlightLayers.forEach { $0.removeFromSuperlayer() }
        highlightLayers = highlights.flatMap { highlight -> [CALayer] in
            guard case .image(_, let rects) = highlight.location else { return [] }
            let (r, g, b) = highlight.color.rgb
            return rects.map { rect in
                let layer = CALayer()
                // Layer coordinates are bottom-up; highlight rects are top-down (0…1).
                layer.frame = CGRect(x: rect.minX * bounds.width - 2, y: (1 - rect.maxY) * bounds.height - 1,
                                     width: rect.width * bounds.width + 4, height: rect.height * bounds.height + 2)
                layer.backgroundColor = NSColor(red: r, green: g, blue: b, alpha: 1).cgColor
                layer.compositingFilter = "multiplyBlendMode"
                layer.cornerRadius = 2
                return layer
            }
        }
        highlightLayers.forEach { layer?.addSublayer($0) }
    }

    override func mouseDown(with event: NSEvent) {
        if canReadFromClick?() == true, event.clickCount == 1, bounds.width > 0 {
            let p = convert(event.locationInWindow, from: nil)
            readFromClick?(index, CGPoint(x: p.x / bounds.width, y: p.y / bounds.height))
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: ImageAnalysisOverlayViewDelegate

    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        onSelectionChange?(overlayView.selectedText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu, for event: NSEvent, at point: CGPoint) -> NSMenu {
        extendMenu?(menu)
        return menu
    }
}
