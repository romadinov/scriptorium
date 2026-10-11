import Foundation

/// The iCloud Drive "Inbox": a folder tree mirroring the library where books can be dropped from any
/// device. `sync()` moves every book from the Inbox into the same folder of the library.
public struct InboxSync: Sendable {
    public struct Report: Sendable, Equatable {
        public var imported: [String] = []          // library-relative paths
        public var duplicates: [String] = []        // already in the library; removed from the Inbox
        public var foldersCreated: [String] = []    // new library folders from the Inbox
        public var skipped: [String] = []           // not a supported book; left in the Inbox
        public var failed: [String: String] = [:]   // inbox-relative path → error

        public var summary: String {
            var parts: [String] = []
            if !imported.isEmpty { parts.append("\(imported.count) book\(imported.count == 1 ? "" : "s") imported") }
            if !foldersCreated.isEmpty { parts.append("\(foldersCreated.count) new folder\(foldersCreated.count == 1 ? "" : "s")") }
            if !duplicates.isEmpty { parts.append("\(duplicates.count) already in the library") }
            if !skipped.isEmpty { parts.append("\(skipped.count) unsupported file\(skipped.count == 1 ? "" : "s") left in the Inbox") }
            if !failed.isEmpty { parts.append("\(failed.count) failed") }
            return parts.isEmpty ? "The Inbox is empty." : parts.joined(separator: ", ") + "."
        }
    }

    public let library: URL
    public let inbox: URL
    /// Makes sure an iCloud item is downloaded before it is read (no-op for local folders).
    public var ensureDownloaded: @Sendable (URL) async throws -> Void

    public init(library: URL, inbox: URL, ensureDownloaded: @escaping @Sendable (URL) async throws -> Void = { try await ICloudFiles.ensureDownloaded($0) }) {
        self.library = library.standardizedFileURL
        self.inbox = inbox.standardizedFileURL
        self.ensureDownloaded = ensureDownloaded
    }

    // MARK: Folder mirroring

    /// Creates every library folder inside the Inbox. Returns how many were added.
    @discardableResult
    public func mirrorFolders() throws -> Int {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var created = 0
        for relative in Self.folders(under: library) {
            let target = inbox.appending(path: relative)
            if !FileManager.default.fileExists(atPath: target.path) {
                try ICloudFiles.coordinatedCreateDirectory(target)
                created += 1
            }
        }
        return created
    }

    /// Mirrors a library folder rename/move — only if the Inbox copy holds no files, so nothing waiting
    /// for import is ever moved or lost.
    public func mirrorMove(from oldRelative: String, to newRelative: String) {
        let old = inbox.appending(path: oldRelative), new = inbox.appending(path: newRelative)
        guard Self.isEmptyTree(old), !FileManager.default.fileExists(atPath: new.path) else { return }
        try? FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ICloudFiles.coordinatedMove(old, to: new)
    }

    /// Mirrors a library folder deletion — only if the Inbox copy holds no files.
    public func mirrorDelete(_ relative: String) {
        let url = inbox.appending(path: relative)
        guard !relative.isEmpty, Self.isEmptyTree(url) else { return }
        try? ICloudFiles.coordinatedDelete(url)
    }

    // MARK: Import

    public func sync() async -> Report {
        var report = Report()
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        // Folders first (shallow before deep), so files always have somewhere to go.
        for relative in Self.folders(under: inbox) {
            let target = library.appending(path: relative)
            if !FileManager.default.fileExists(atPath: target.path) {
                do {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    report.foldersCreated.append(relative)
                } catch {
                    report.failed[relative] = error.localizedDescription
                }
            }
        }

        for (relative, url) in Self.files(under: inbox) {
            // Background runs can be cut short; whatever was already moved stays moved.
            if Task.isCancelled { break }
            let name = url.lastPathComponent
            guard DocumentOpener.canOpen(url) else {
                report.skipped.append(relative)
                continue
            }
            let folder = library.appending(path: (relative as NSString).deletingLastPathComponent)
            do {
                try await ensureDownloaded(url)
                let existing = folder.appending(path: name)
                if FileManager.default.fileExists(atPath: existing.path),
                   (try? DocumentFingerprint.id(for: existing)) == (try? DocumentFingerprint.id(for: url)) {
                    try ICloudFiles.coordinatedDelete(url)
                    report.duplicates.append(relative)
                    continue
                }
                let destination = LibraryFiles.uniqueURL(for: name, in: folder)
                try ICloudFiles.coordinatedCopy(url, to: destination)
                try ICloudFiles.coordinatedDelete(url)
                report.imported.append(String(destination.path.dropFirst(library.path.count + 1)))
            } catch {
                report.failed[relative] = error.localizedDescription
            }
        }

        _ = try? mirrorFolders()
        return report
    }

    // MARK: Tree walking

    /// Relative paths of all folders, parents before children.
    static func folders(under root: URL) -> [String] {
        walk(root).filter(\.isDirectory).map(\.relative).sorted { $0.split(separator: "/").count < $1.split(separator: "/").count }
    }

    /// Files (including not-yet-downloaded iCloud placeholders, reported under their real name).
    static func files(under root: URL) -> [(relative: String, url: URL)] {
        walk(root).filter { !$0.isDirectory }.map { ($0.relative, $0.url) }
    }

    private static func walk(_ root: URL) -> [(relative: String, url: URL, isDirectory: Bool)] {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsPackageDescendants]) else { return [] }
        var items: [(String, URL, Bool)] = []
        for case let url as URL in enumerator {
            var name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            var itemURL = url
            if name.hasPrefix(".") {
                // Older iCloud placeholders: ".Book.pdf.icloud" stands for "Book.pdf".
                guard !isDirectory, name.hasSuffix(".icloud") else {
                    if isDirectory { enumerator.skipDescendants() }
                    continue
                }
                name = String(name.dropFirst().dropLast(".icloud".count))
                itemURL = url.deletingLastPathComponent().appending(path: name)
            }
            // Resolve via the parent, which exists even when the item is an iCloud placeholder.
            let parent = itemURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            let full = parent + "/" + name
            guard full.hasPrefix(base + "/") else { continue }
            items.append((String(full.dropFirst(base.count + 1)), itemURL, isDirectory))
        }
        return items
    }

    /// True if any supported book is waiting in the Inbox.
    public static func hasBooks(in inbox: URL) -> Bool {
        files(under: inbox).contains { DocumentOpener.canOpen($0.url) }
    }

    static func isEmptyTree(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return files(under: url).isEmpty
    }
}

/// Coordinated file operations and download handling for iCloud Drive (also correct for local folders).
public enum ICloudFiles {
    public struct DownloadTimeout: LocalizedError {
        public var errorDescription: String? { "Timed out downloading from iCloud" }
    }

    /// The container's public Documents folder, or nil if iCloud Drive is unavailable. Blocks; call off the main thread.
    public static func documentsDirectory(containerIdentifier: String?) -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)?.appending(path: "Documents")
    }

    public static func ensureDownloaded(_ url: URL) async throws {
        guard FileManager.default.isUbiquitousItem(at: url) else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            var copy = url
            copy.removeAllCachedResourceValues()
            let status = try? copy.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            if status == .current || status == .downloaded { return }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw DownloadTimeout()
    }

    static func coordinate(_ body: (NSFileCoordinator, inout NSError?) -> Void) throws {
        var error: NSError?
        body(NSFileCoordinator(), &error)
        if let error { throw error }
    }

    public static func coordinatedCopy(_ source: URL, to destination: URL) throws {
        var inner: Error?
        try coordinate { c, e in
            c.coordinate(readingItemAt: source, options: [], writingItemAt: destination, options: .forReplacing, error: &e) { r, w in
                do { try FileManager.default.copyItem(at: r, to: w) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }

    public static func coordinatedDelete(_ url: URL) throws {
        var inner: Error?
        try coordinate { c, e in
            c.coordinate(writingItemAt: url, options: .forDeleting, error: &e) { u in
                do { try FileManager.default.removeItem(at: u) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }

    public static func coordinatedMove(_ source: URL, to destination: URL) throws {
        var inner: Error?
        try coordinate { c, e in
            c.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &e) { s, d in
                do { try FileManager.default.moveItem(at: s, to: d) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }

    public static func coordinatedCreateDirectory(_ url: URL) throws {
        var inner: Error?
        try coordinate { c, e in
            c.coordinate(writingItemAt: url, options: [], error: &e) { u in
                do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }
}
