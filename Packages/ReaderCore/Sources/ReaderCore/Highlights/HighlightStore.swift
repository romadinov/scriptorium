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
        if merged.highlights.isEmpty {
            try? coordinatedDelete(markdownURL)
        } else {
            try coordinatedWrite(Data(merged.markdown(locationLabel: locationLabel).utf8), to: markdownURL)
        }
        return merged
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
