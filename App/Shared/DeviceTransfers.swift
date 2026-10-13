import Foundation
import Observation
import os
import ReaderCore

private let log = Logger(subsystem: "com.romadinov.reader", category: "Transfers")

/// "Send to iPhone / MacBook…": registers this device in iCloud, sends books to the others, and imports
/// books sent here (into the same library folders), deleting them from iCloud once imported.
@MainActor @Observable
final class DeviceTransfers {
    static let shared = DeviceTransfers()

    /// Other devices that can receive books.
    private(set) var devices: [DeviceInfo] = []
    /// Library-relative paths of books received while the app was open (shown as a banner).
    var received: [String] = []
    /// "Sending to iPhone…", "Sent “X” to iPhone" — for the library/reader status line.
    var status: String?
    /// Called after books were imported, so library views reload.
    @ObservationIgnored var onImported: (() -> Void)?

    @ObservationIgnored private var directory: DeviceDirectory?
    @ObservationIgnored private var isCloud = false
    @ObservationIgnored private var importing = false
    @ObservationIgnored private lazy var watcher = InboxWatcher { [weak self] in
        Task { await self?.importArrivals() }
    }

    /// On launch and whenever the app comes to the front.
    func start() async {
        if directory == nil {
            let (root, cloud) = await Task.detached(priority: .utility) { Self.resolveRoot() }.value
            directory = DeviceDirectory(root: root)
            isCloud = cloud
        }
        guard let directory else { return }
        let me = DeviceInfo(id: DeviceIdentity.id, name: DeviceIdentity.name, kind: DeviceIdentity.kind)
        await Task.detached(priority: .utility) { try? directory.register(me) }.value
        await refreshDevices()
        watcher.start(inbox: directory.transfers(for: DeviceIdentity.id), isCloud: isCloud, scope: NSMetadataQueryUbiquitousDataScope)
        await importArrivals()
    }

    func stop() { watcher.stop() }

    func refreshDevices() async {
        guard let directory else { return }
        let me = DeviceIdentity.id
        devices = await Task.detached(priority: .utility) { directory.devices(excluding: me) }.value
    }

    /// Copies the book into the device's transfer folder; iCloud uploads it in the background.
    func send(_ book: URL, folder: String, to device: DeviceInfo) {
        guard let directory else { return }
        let title = book.deletingPathExtension().lastPathComponent
        status = "Sending “\(title)” to \(device.name)…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try directory.send(book, folder: folder, to: device.id) }.value
                status = "Sent “\(title)” to \(device.name). It appears there next time Scriptorium is open."
            } catch {
                status = "Couldn't send “\(title)”: \(error.localizedDescription)"
            }
        }
    }

    func importArrivals() async {
        guard let directory, !importing else { return }
        let inbox = directory.transfers(for: DeviceIdentity.id)
        guard InboxSync.hasBooks(in: inbox) else { return }
        importing = true
        defer { importing = false }
        let report = await Task.detached(priority: .userInitiated) {
            await InboxSync(library: LibraryStore.rootURL, inbox: inbox).sync()
        }.value
        log.info("Received: \(report.summary, privacy: .public)")
        if !report.imported.isEmpty {
            received += report.imported
            onImported?()
        }
    }

    /// The iCloud container (hidden from Files), or local Documents without iCloud (simulator).
    nonisolated static func resolveRoot() -> (URL, Bool) {
        if let cloud = DeviceDirectory.iCloudRoot(containerIdentifier: InboxLocation.containerIdentifier) { return (cloud, true) }
        return (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Devices"), false)
    }

    /// Background (iPad/iPhone): import anything sent here; returns library paths imported.
    nonisolated static func importInBackground() async -> [String] {
        let (root, _) = resolveRoot()
        let inbox = DeviceDirectory(root: root).transfers(for: DeviceIdentity.id)
        guard InboxSync.hasBooks(in: inbox) else { return [] }
        return await InboxSync(library: LibraryStore.rootURL, inbox: inbox).sync().imported
    }
}
