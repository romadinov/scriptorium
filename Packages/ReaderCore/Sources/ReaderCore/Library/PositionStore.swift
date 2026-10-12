import Foundation

/// Where a device last was in a book, shared through iCloud so another device can offer to continue there.
public struct SyncedPosition: Codable, Sendable, Equatable {
    /// Page (fixed layout) or chapter (reflowable).
    public var page: Int
    /// Position within the chapter, 0…1 (reflowable); 0 for fixed layout.
    public var progress: Double
    /// As shown on that device, e.g. "p. 120".
    public var label: String
    public var updated: Date
    public var device: String
    public var deviceID: String

    public init(page: Int, progress: Double, label: String, updated: Date = Date(), device: String, deviceID: String) {
        self.page = page
        self.progress = progress
        self.label = label
        self.updated = updated
        self.device = device
        self.deviceID = deviceID
    }

    /// Worth offering instead of `local`: newer than the local save (with a little slack for clock skew)
    /// and actually somewhere else in the book.
    public func shouldOffer(over localPage: Int, _ localProgress: Double, savedAt localDate: Date?) -> Bool {
        guard updated > (localDate ?? .distantPast).addingTimeInterval(5) else { return false }
        return page != localPage || abs(progress - localProgress) > 0.02
    }
}

/// Reading positions in the iCloud container (hidden from Files):
///
///     <container>/Positions/<documentID>/<deviceID>.json
///
/// Each device only ever writes its own file, so devices never overwrite each other.
public actor PositionStore {
    private var directory: URL
    private let containerIdentifier: String?
    private var resolved: Bool

    public init(root: URL? = nil, containerIdentifier: String? = nil) {
        self.containerIdentifier = containerIdentifier
        directory = (root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]).appending(path: "Positions")
        resolved = root != nil
    }

    private func resolve() {
        guard !resolved else { return }
        resolved = true
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) {
            directory = container.appending(path: "Positions")
        }
    }

    public func save(_ position: SyncedPosition, documentID: String) {
        resolve()
        let folder = directory.appending(path: documentID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(position.deviceID).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(position) else { return }
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Positions saved by other devices, newest first (starts downloading any that aren't local yet).
    public func others(documentID: String, excluding deviceID: String) -> [SyncedPosition] {
        resolve()
        let folder = directory.appending(path: documentID)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [SyncedPosition] = []
        for file in files {
            var name = file.lastPathComponent
            var target = file
            if name.hasPrefix("."), name.hasSuffix(".icloud") {             // not downloaded yet
                name = String(name.dropFirst().dropLast(7))
                target = folder.appending(path: name)
                try? FileManager.default.startDownloadingUbiquitousItem(at: target)
                continue
            }
            guard name.hasSuffix(".json"), name != "\(deviceID).json" else { continue }
            var data: Data?
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: target, options: [], error: &error) { data = try? Data(contentsOf: $0) }
            if let data, let position = try? decoder.decode(SyncedPosition.self, from: data) { result.append(position) }
        }
        return result.sorted { $0.updated > $1.updated }
    }
}
