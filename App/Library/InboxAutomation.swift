#if os(iOS)
import BackgroundTasks
#endif
import Foundation
import os
import ReaderCore

private let log = Logger(subsystem: "com.romadinov.reader", category: "Inbox")

/// Where the Inbox lives: the iCloud container when available, else local Documents (simulator, no iCloud).
enum InboxLocation {
    static let containerIdentifier = "iCloud.com.romadinov.reader"

    /// iCloud Drive › Scriptorium › Read Later.md (or On My iPad › Scriptorium › Read Later.md).
    static func readLaterFile() -> URL {
        let base = ICloudFiles.documentsDirectory(containerIdentifier: containerIdentifier)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Read Later.md")
    }

    /// iCloud Drive › Scriptorium › Improvement notes.md (or the local Documents fallback).
    static func improvementNotesFile() -> URL {
        let base = ICloudFiles.documentsDirectory(containerIdentifier: containerIdentifier)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Improvement notes.md")
    }

    /// Blocks while iCloud resolves the container — call off the main thread.
    static func resolve() -> (url: URL, isCloud: Bool) {
        if let documents = ICloudFiles.documentsDirectory(containerIdentifier: containerIdentifier) {
            return (documents.appending(path: "Inbox"), true)
        }
        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return (local.appending(path: "Inbox"), false)
    }
}

/// Watches the Inbox while the app is in the foreground: starts downloading new iCloud files as soon as
/// they appear and calls `onReady` once there are books ready to import.
@MainActor
final class InboxWatcher {
    private var query: NSMetadataQuery?
    private var poll: Timer?
    private var debounce: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let onReady: @MainActor () -> Void

    init(onReady: @escaping @MainActor () -> Void) {
        self.onReady = onReady
    }

    /// `scope`: the Inbox is in the container's Documents; device transfers are in its hidden data area.
    func start(inbox: URL, isCloud: Bool, scope: String = NSMetadataQueryUbiquitousDocumentsScope) {
        stop()
        if isCloud {
            let query = NSMetadataQuery()
            query.searchScopes = [scope]
            query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, inbox.standardizedFileURL.path)
            query.notificationBatchingInterval = 1
            for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.process() }
                })
            }
            query.start()
            self.query = query
        } else {
            // Local fallback (no iCloud account): check now, then a light poll; the tolerance lets iOS batch wake-ups.
            if InboxSync.hasBooks(in: inbox) { scheduleImport() }
            poll = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if InboxSync.hasBooks(in: inbox) { self.scheduleImport() }
                }
            }
        }
        poll?.tolerance = 10
        log.debug("Watching inbox \(inbox.path, privacy: .public) (iCloud: \(isCloud))")
    }

    func stop() {
        query?.stop()
        query = nil
        poll?.invalidate()
        poll = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func process() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        var ready = false
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  DocumentOpener.canOpen(url) else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status == NSMetadataUbiquitousItemDownloadingStatusCurrent {
                ready = true
            } else {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        if ready { scheduleImport() }
    }

    /// Several files often land together; import once they've settled.
    private func scheduleImport() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.onReady()
        }
    }
}

#if os(iOS)
/// Background import via BGTaskScheduler. iPadOS decides when these run (typically while idle/charging);
/// each run imports whatever is in the Inbox and remembers the result for the next time the app opens.
enum InboxBackgroundImport {
    static let refreshID = "com.romadinov.reader.inbox.refresh"
    static let processingID = "com.romadinov.reader.inbox.import"
    private static let pendingReportKey = "inbox.backgroundImported"

    /// Must run before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in run(task) }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in run(task) }
    }

    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.requiresNetworkConnectivity = true   // files may still need downloading from iCloud
        processing.requiresExternalPower = true         // big imports wait for the charger
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        for request in [refresh, processing] as [BGTaskRequest] {
            do { try BGTaskScheduler.shared.submit(request) } catch {
                log.error("Couldn't schedule \(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func run(_ task: BGTask) {
        schedule()   // keep the chain going
        let work = Task.detached(priority: .utility) {
            let report = await LibraryStore.usesInbox
                ? await InboxSync(library: LibraryStore.rootURL, inbox: InboxLocation.resolve().url).sync() : nil
            let sent = await DeviceTransfers.importInBackground()      // books other devices sent here
            let imported = (report?.imported ?? []) + sent
            if !imported.isEmpty {
                let previous = UserDefaults.standard.stringArray(forKey: pendingReportKey) ?? []
                UserDefaults.standard.set(previous + imported, forKey: pendingReportKey)
            }
            log.info("Background import: \(report?.summary ?? "no Inbox", privacy: .public); \(sent.count) sent here")
            task.setTaskCompleted(success: report?.failed.isEmpty ?? true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Books imported in the background since the app was last opened (and clears the list).
    static func takeBackgroundImports() -> [String] {
        let imported = UserDefaults.standard.stringArray(forKey: pendingReportKey) ?? []
        UserDefaults.standard.removeObject(forKey: pendingReportKey)
        return imported
    }
}
#endif
