import Foundation

/// One of the reader's devices, as registered in iCloud so others can send books to it.
public struct DeviceInfo: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case iPad, iPhone, mac }

    public var id: String
    public var name: String
    public var kind: Kind
    public var lastSeen: Date
    /// The device's library folders (library-relative, e.g. "Physics/Thermo"), so a sender can pick one.
    public var folders: [String]?

    public init(id: String, name: String, kind: Kind, lastSeen: Date = Date(), folders: [String]? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.lastSeen = lastSeen
        self.folders = folders
    }

    /// Library folders of a library rooted at `root` (relative paths, sorted), for registration.
    public static func folders(in root: URL) -> [String] {
        let base = root.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var result: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(base + "/") { result.append(String(path.dropFirst(base.count + 1))) }
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var systemImage: String {
        switch kind {
        case .iPad: "ipad"
        case .iPhone: "iphone"
        case .mac: "laptopcomputer"
        }
    }
}

/// Sending books between devices through the iCloud container (hidden from Files):
///
///     <container>/Devices/<deviceID>.json        — each device registers itself (its own file only)
///     <container>/Transfers/<deviceID>/<folder>/  — books sent to that device, until it imports them
///
/// The receiver imports from its Transfers folder with `InboxSync` (same folders as the sender's library)
/// and deletes what it imported, so books are in iCloud only while in transit.
public struct DeviceDirectory: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The iCloud container's root (nil without iCloud). Blocks; call off the main thread.
    public static func iCloudRoot(containerIdentifier: String?) -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)
    }

    public func transfers(for deviceID: String) -> URL {
        root.appending(path: "Transfers").appending(path: deviceID)
    }

    private var devicesFolder: URL { root.appending(path: "Devices") }

    public func register(_ device: DeviceInfo) throws {
        try FileManager.default.createDirectory(at: devicesFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transfers(for: device.id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(device)
        var error: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: devicesFolder.appending(path: "\(device.id).json"), options: .forReplacing,
                                       error: &error) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let failure = error ?? writeError { throw failure }
    }

    /// Other registered devices, most recently seen first (starts downloading any not yet local).
    public func devices(excluding deviceID: String, seenWithin interval: TimeInterval = 180 * 24 * 3600) -> [DeviceInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: devicesFolder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [DeviceInfo] = []
        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                try? FileManager.default.startDownloadingUbiquitousItem(
                    at: devicesFolder.appending(path: String(name.dropFirst().dropLast(7))))
                continue
            }
            guard name.hasSuffix(".json"), name != "\(deviceID).json" else { continue }
            var data: Data?
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &error) { data = try? Data(contentsOf: $0) }
            if let data, let device = try? decoder.decode(DeviceInfo.self, from: data),
               device.lastSeen > Date().addingTimeInterval(-interval) {
                result.append(device)
            }
        }
        return result.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Copies `book` into `device`'s Transfers folder under `folder` (library-relative, "" for the top).
    /// Returns where it went. A name already waiting there gets " 2", " 3"… so nothing is overwritten.
    @discardableResult
    public func send(_ book: URL, folder: String, to deviceID: String) throws -> URL {
        var directory = transfers(for: deviceID)
        for part in folder.split(separator: "/") where !part.isEmpty && part != ".." { directory = directory.appending(path: String(part)) }
        try ICloudFiles.coordinatedCreateDirectory(directory)
        let ext = book.pathExtension
        let base = book.deletingPathExtension().lastPathComponent
        var target = directory.appending(path: book.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appending(path: "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        try ICloudFiles.coordinatedCopy(book, to: target)
        return target
    }
}
