import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

/// Manual probe: DJVU_PROBE_DIR=/dir swift test --filter probeDjVuRendering — renders a few pages of each
/// file and reports how much of each is ink, to find documents that come out blank.
@Test(.enabled(if: ProcessInfo.processInfo.environment["DJVU_PROBE_DIR"] != nil))
func probeDjVuRendering() throws {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DJVU_PROBE_DIR"]!)
    for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
    where url.pathExtension.lowercased().hasPrefix("djv") {
        let start = Date()
        do {
            let source = try DjVuPageSource(url: url)
            var report: [String] = []
            for page in [0, 1, 4, 20].filter({ $0 < source.pageCount }) {
                do {
                    let image = try source.renderPage(at: page, maxPixelSize: 600)
                    report.append("p\(page + 1)=\(String(format: "%.1f%%", ink(image) * 100)) \(image.width)x\(image.height)")
                } catch {
                    report.append("p\(page + 1)=ERROR \(error)")
                }
            }
            print("DJVU \(url.lastPathComponent.prefix(50)) pages=\(source.pageCount) \(report.joined(separator: " ")) \(String(format: "%.1fs", Date().timeIntervalSince(start)))")
        } catch {
            print("DJVU \(url.lastPathComponent.prefix(50)) OPEN ERROR \(error)")
        }
    }
}

/// Share of pixels darker than near-white.
private func ink(_ image: CGImage) -> Double {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return -1 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return Double(pixels.filter { $0 < 200 }.count) / Double(w * h)
}
