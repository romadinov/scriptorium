import Foundation
import Testing
@testable import ReaderCore

/// Manual quality check on a real book: REFLOW_PROBE=<book path> REFLOW_PAGES=20-23 REFLOW_OUT=<dir> swift test --filter ReflowProbe
@Suite struct ReflowProbe {
    @Test func convertRealPages() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["REFLOW_PROBE"], let out = env["REFLOW_OUT"] else { return }
        let url = URL(fileURLWithPath: path)
        let source = try DocumentOpener.open(url)
        let bounds = (env["REFLOW_PAGES"] ?? "0-2").split(separator: "-").compactMap { Int($0) }
        for page in bounds[0]...bounds[1] where page < source.pageCount {
            if env["REFLOW_RENDER"] != nil {   // the original page, to compare
                try PageReflower.writePNG(try source.renderPage(at: page, maxPixelSize: 1400),
                                          to: URL(fileURLWithPath: out).appending(path: "original-\(page + 1).png"))
            }
            let start = Date()
            try await PageReflower.convert(source, page: page, into: URL(fileURLWithPath: out), languages: ["ru-RU", "en-US"])
            print("PROBE page \(page + 1): \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        }
    }
}
