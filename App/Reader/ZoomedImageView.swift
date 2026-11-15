import SwiftUI
import UIKit

/// A picture from a text book, full screen: pinch or double-tap to zoom, drag to pan, swipe down or Done to close.
struct ZoomedImageView: View {
    let url: URL
    let onClose: () -> Void
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomingImage(image: image, onSwipeDown: onClose)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("zoomedImage")
            } else {
                ProgressView().tint(.white)
            }
            Button("Done", systemImage: "xmark") { onClose() }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .padding(12)
                .glassEffect(in: .circle)
                .padding()
                .accessibilityIdentifier("zoomedImage.close")
        }
        .environment(\.colorScheme, .dark)
        .task(id: url) {
            let url = url
            image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let image = UIImage(data: data) else { return nil }
                return image.preparingForDisplay() ?? image
            }.value
            if image == nil { onClose() }   // SVG or unreadable: nothing to show
        }
    }
}

private struct ZoomingImage: UIViewRepresentable {
    let image: UIImage
    let onSwipeDown: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSwipeDown: onSwipeDown) }

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(image: image)
        view.delegate = context.coordinator
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
        swipe.direction = .down
        view.addGestureRecognizer(swipe)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let onSwipeDown: () -> Void
        init(onSwipeDown: @escaping () -> Void) { self.onSwipeDown = onSwipeDown }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ZoomScrollView)?.imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { (scrollView as? ZoomScrollView)?.centerImage() }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ZoomScrollView else { return }
            if view.zoomScale > view.minimumZoomScale * 1.05 {
                view.setZoomScale(view.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: view.imageView)
                let scale = min(view.maximumZoomScale, view.minimumZoomScale * 3)
                let size = CGSize(width: view.bounds.width / scale, height: view.bounds.height / scale)
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), animated: true)
            }
        }

        /// Only when not zoomed in (then a swipe pans the picture).
        @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
            guard let view = gesture.view as? ZoomScrollView, view.zoomScale <= view.minimumZoomScale * 1.01 else { return }
            onSwipeDown()
        }
    }
}

final class ZoomScrollView: UIScrollView {
    let imageView: UIImageView
    private var fittedSize: CGSize = .zero

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        // On white, like the page: line art and transparent pictures would vanish on black.
        imageView.backgroundColor = .white
        addSubview(imageView)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != fittedSize, bounds.width > 0, let size = imageView.image?.size, size.width > 0 else { return }
        fittedSize = bounds.size
        // Fit the whole picture; allow zooming to 4× its own pixels (small figures still get big).
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        minimumZoomScale = fit
        maximumZoomScale = max(fit * 6, 4)
        zoomScale = fit
        centerImage()
    }

    func centerImage() {
        let content = imageView.frame.size
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - content.height) / 2),
                                    left: max(0, (bounds.width - content.width) / 2),
                                    bottom: 0, right: 0)
    }
}
