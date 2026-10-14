#if DEBUG
import AppKit
import WebKit

/// Development aid: `-snapshotAfter 8` makes the app render each of its windows to PNG files in
/// <container>/Documents/Snapshots after 8 seconds and quit — a look at the UI without screen-recording
/// permission or driving the mouse. Web views render out of process, so they're snapshotted separately.
@MainActor
enum DebugSnapshots {
    static func scheduleIfRequested() {
        let delay = UserDefaults.standard.double(forKey: "snapshotAfter")
        guard delay > 0 else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await capture()
            NSApp.terminate(nil)
        }
    }

    private static func capture() async {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Snapshots")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let name = window.title.isEmpty ? "window-\(i)" : window.title.replacingOccurrences(of: "/", with: "-")
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
            }
            for (j, web) in webViews(in: view).enumerated() {
                if let image = try? await web.takeSnapshot(configuration: nil),
                   let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name)-web\(j).png"))
                }
            }
        }
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews(in:))
    }
}
#endif
