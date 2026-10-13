import Foundation
import MetricKit
import os
import ReaderCore

private let log = Logger(subsystem: "com.romadinov.reader", category: "Diagnostics")

/// Saves crash (and hang / resource exception) reports from MetricKit to iCloud Drive › Scriptorium ›
/// Crash reports, one file per report, so they reach the Mac for analysis. MetricKit delivers a report on
/// the launch after the problem; nothing is sent anywhere else.
final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReporter()
    private var device = "Device"

    /// Call at launch, on the main thread.
    @MainActor func start() {
        device = DeviceIdentity.name
        MXMetricManager.shared.add(self)
        // Anything delivered while the app wasn't listening (e.g. before this build).
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        if !past.isEmpty { save(past) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads) }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        let device = device
        Task.detached(priority: .utility) {
            let folder = (ICloudFiles.documentsDirectory(containerIdentifier: InboxLocation.containerIdentifier)
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]).appending(path: "Crash reports")
            try? ICloudFiles.coordinatedCreateDirectory(folder)
            let info = Bundle.main.infoDictionary
            let build = info?["CFBundleVersion"] as? String ?? "?"
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            for payload in payloads {
                let crashes = payload.crashDiagnostics?.count ?? 0
                let hangs = payload.hangDiagnostics?.count ?? 0
                let other = (payload.cpuExceptionDiagnostics?.count ?? 0) + (payload.diskWriteExceptionDiagnostics?.count ?? 0)
                guard crashes + hangs + other > 0 else { continue }
                let kind = crashes > 0 ? "Crash" : (hangs > 0 ? "Hang" : "Resource")
                let name = "\(kind) \(formatter.string(from: payload.timeStampEnd)) \(device) build \(build).json"
                let url = folder.appending(path: name.replacingOccurrences(of: "/", with: "-"))
                guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                var error: NSError?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
                    try? payload.jsonRepresentation().write(to: target, options: .atomic)
                }
                log.info("Saved diagnostic report \(name, privacy: .public)")
            }
        }
    }
}
