import Foundation

/// Persists highlights in iCloud Drive when available (falls back to local Documents):
///
///     <container>/Highlights/<documentID>.json      — data, synced but hidden from Files
///     <container>/Documents/Highlights/<Title>.md   — readable copy, visible in Files › iCloud Drive › Scriptorium
///
/// Writes are coordinated (NSFileCoordinator) and always merge with what is on disk, so edits made
/// on another device in the meantime are kept.
public actor HighlightStore {
    public enum Backend: Sendable, Equatable {
        case iCloud
        case local
    }

    public private(set) var backend: Backend = .local
    private var dataDirectory: URL
    private var textDirectory: URL
    private let containerIdentifier: String?
    private var resolved = false

    /// - Parameter root: fixed directory (tests); `nil` resolves the iCloud container, else local Documents.
    public init(root: URL? = nil, containerIdentifier: String? = nil) {
        self.containerIdentifier = containerIdentifier
        let base = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dataDirectory = base.appending(path: "Highlights/Data")
        textDirectory = base.appending(path: "Highlights")
        resolved = root != nil
    }

    /// Looks up the iCloud container once (must not run on the main thread — it can block).
    public func resolveBackend() -> Backend {
        guard !resolved else { return backend }
        resolved = true
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) {
            dataDirectory = container.appending(path: "Highlights")
            textDirectory = container.appending(path: "Documents/Highlights")
            backend = .iCloud
        }
        return backend
    }

    public func load(documentID: String) -> BookHighlights? {
        _ = resolveBackend()
        let url = dataURL(documentID)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return coordinatedRead(url)
    }

    /// Merges `book` with the stored copy, writes JSON + Markdown, and returns the merged result.
    @discardableResult
    public func save(_ book: BookHighlights, locationLabel: @Sendable (Highlight.Location) -> String) throws -> BookHighlights {
        _ = resolveBackend()
        let url = dataURL(book.documentID)
        var merged = book
        if let existing = coordinatedRead(url) { merged = book.merged(with: existing) }
        merged.updated = Date()

        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try coordinatedWrite(encoder.encode(merged), to: url)

        let markdownURL = textDirectory.appending(path: Self.fileSafe(merged.title) + ".md")
        if merged.highlights.isEmpty && merged.bookmarks.isEmpty {
            try? coordinatedDelete(markdownURL)
        } else {
            try coordinatedWrite(Data(merged.markdown(locationLabel: locationLabel).utf8), to: markdownURL)
        }
        return merged
    }

    /// Every book's highlights and bookmarks (for the all-bookmarks view and search).
    public func allBooks() -> [BookHighlights] {
        _ = resolveBackend()
        let files = (try? FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> BookHighlights? in
            var name = url.lastPathComponent
            var target = url
            if name.hasPrefix("."), name.hasSuffix(".icloud") {          // not downloaded yet
                name = String(name.dropFirst().dropLast(7))
                target = url.deletingLastPathComponent().appending(path: name)
                try? FileManager.default.startDownloadingUbiquitousItem(at: target)
            }
            guard name.hasSuffix(".json") else { return nil }
            return coordinatedRead(target)
        }
    }

    // MARK: Drawings
    //
    //     <container>/Highlights/Drawings/<id>.drawing          — PencilKit data, for editing
    //     <container>/Documents/Highlights/Drawings/<id>.png    — picture, linked from the Markdown
    //
    // Every edit saves under a new id, so devices never overwrite each other's drawing files.

    public func saveDrawing(id: UUID, data: Data, png: Data?) throws {
        _ = resolveBackend()
        let dataDir = dataDirectory.appending(path: "Drawings")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try coordinatedWrite(data, to: dataDir.appending(path: "\(id.uuidString).drawing"))
        if let png {
            let pictureDir = textDirectory.appending(path: "Drawings")
            try FileManager.default.createDirectory(at: pictureDir, withIntermediateDirectories: true)
            try coordinatedWrite(png, to: pictureDir.appending(path: "\(id.uuidString).png"))
        }
    }

    /// The drawing's data, downloading it from iCloud first if needed (waits up to ~10 s).
    public func loadDrawing(id: UUID) async -> Data? {
        _ = resolveBackend()
        let url = dataDirectory.appending(path: "Drawings/\(id.uuidString).drawing")
        for attempt in 0..<20 {
            if let data = coordinatedData(url) { return data }
            if attempt == 0 { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
            guard backend == .iCloud else { return nil }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    public func deleteDrawing(id: UUID) {
        _ = resolveBackend()
        try? coordinatedDelete(dataDirectory.appending(path: "Drawings/\(id.uuidString).drawing"))
        try? coordinatedDelete(textDirectory.appending(path: "Drawings/\(id.uuidString).png"))
    }

    public var textFolderDescription: String {
        backend == .iCloud ? "iCloud Drive › Scriptorium › Highlights" : "On My iPad › Scriptorium › Highlights"
    }

    // MARK: Files

    private func dataURL(_ documentID: String) -> URL {
        dataDirectory.appending(path: "\(documentID).json")
    }

    static func fileSafe(_ title: String) -> String {
        let cleaned = title.map { "/\\:?%*|\"<>".contains($0) ? "-" : $0 }
        return String(String(cleaned).trimmingCharacters(in: .whitespaces).prefix(120))
    }

    private func coordinatedData(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { result = try? Data(contentsOf: $0) }
        return result
    }

    private func coordinatedRead(_ url: URL) -> BookHighlights? {
        var result: BookHighlights?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            result = try? decoder.decode(BookHighlights.self, from: data)
        }
        return result
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            do { try data.write(to: writeURL, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    private func coordinatedDelete(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { deleteURL in
            try? FileManager.default.removeItem(at: deleteURL)
        }
        if let coordinationError { throw coordinationError }
    }
}
