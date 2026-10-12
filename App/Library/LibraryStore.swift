import Foundation
import Observation
import ReaderCore
import UniformTypeIdentifiers

struct Book: Identifiable, Hashable {
    var url: URL
    var id: URL { url }

    var title: String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".fb2.zip") { return String(name.dropLast(8)) }
        return url.deletingPathExtension().lastPathComponent
    }

    var format: String {
        url.lastPathComponent.lowercased().hasSuffix(".fb2.zip") ? "FB2" : url.pathExtension.uppercased()
    }

    var isDjVu: Bool { ["djvu", "djv"].contains(url.pathExtension.lowercased()) }
}

struct Folder: Identifiable, Hashable {
    var url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum LibraryRoute: Hashable {
    case folder(Folder)
    case book(Book)
}

extension UTType {
    static let djvu = UTType(importedAs: "org.djvu.djvu")
    static let fb2 = UTType(importedAs: "org.gribuser.fb2")
    static let chm = UTType(filenameExtension: "chm") ?? UTType(importedAs: "com.microsoft.chm")
}

/// Books live in Documents/Books, organised in folders (also visible in the Files app).
/// Reading positions are stored in UserDefaults, keyed by path relative to the library root.
@MainActor @Observable
final class LibraryStore {
    var path: [LibraryRoute] = []
    /// Bumped whenever files change, so folder views reload.
    private(set) var revision = 0

    /// Documents/Books — static so background tasks can import without the UI.
    nonisolated static let rootURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appending(path: "Books")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.standardizedFileURL
    }()

    var root: URL { Self.rootURL }

    var rootFolder: Folder { Folder(url: root) }

    // MARK: iCloud Inbox

    /// iCloud Drive › Scriptorium › Inbox (or On My iPad › Scriptorium › Inbox without iCloud).
    private(set) var inbox: InboxSync?
    private(set) var inboxLocation = ""
    private(set) var isSyncingInbox = false
    private var inboxIsCloud = false
    /// Books imported automatically (watcher or background), shown as a banner in the library.
    var autoImported: [String] = []
    @ObservationIgnored private lazy var watcher = InboxWatcher { [weak self] in
        Task { await self?.autoImport() }
    }

    init() {
        // The iCloud Inbox is iPad-only; on the Mac the library is just local.
        #if os(iOS)
        Task { await resolveInbox() }
        #endif
    }

    private func resolveInbox() async {
        let root = root
        let (url, isCloud) = await Task.detached(priority: .utility) { InboxLocation.resolve() }.value
        let sync = InboxSync(library: root, inbox: url)
        inbox = sync
        inboxIsCloud = isCloud
        inboxLocation = isCloud ? "iCloud Drive › Scriptorium › Inbox" : "On My iPad › Scriptorium › Inbox"
        await Task.detached(priority: .utility) { _ = try? sync.mirrorFolders() }.value
        startWatchingInbox()
    }

    /// Foreground: watch the Inbox and import new books as they arrive.
    func startWatchingInbox() {
        #if os(iOS)
        let background = InboxBackgroundImport.takeBackgroundImports()
        if !background.isEmpty { autoImported += background }
        #endif
        guard let inbox else { return }
        watcher.start(inbox: inbox.inbox, isCloud: inboxIsCloud)
        Task { await autoImport() }   // anything that arrived while we were away
    }

    func stopWatchingInbox() {
        watcher.stop()
    }

    private func autoImport() async {
        guard let inbox, InboxSync.hasBooks(in: inbox.inbox) else { return }
        if let report = await syncInbox(), !report.imported.isEmpty {
            autoImported += report.imported
        }
    }

    /// Imports everything waiting in the Inbox into the matching library folders and empties the Inbox.
    func syncInbox() async -> InboxSync.Report? {
        if inbox == nil { await resolveInbox() }
        guard let inbox, !isSyncingInbox else { return nil }
        isSyncingInbox = true
        defer { isSyncingInbox = false }
        let report = await Task.detached(priority: .userInitiated) { await inbox.sync() }.value
        reload()
        return report
    }

    private func mirrorInboxFolders() {
        guard let inbox else { return }
        Task.detached(priority: .utility) { _ = try? inbox.mirrorFolders() }
    }

    func reload() { revision += 1 }

    func contents(of folder: Folder) -> (folders: [Folder], books: [Book]) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder.url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        var folders: [Folder] = [], books: [Book] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                folders.append(Folder(url: url))
            } else if DocumentOpener.canOpen(url) {
                books.append(Book(url: url))
            }
        }
        return (folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }

    /// Every folder in the library, depth-first, for the "Move to…" picker.
    func allFolders() -> [(folder: Folder, depth: Int)] {
        func walk(_ folder: Folder, depth: Int) -> [(Folder, Int)] {
            [(folder, depth)] + contents(of: folder).folders.flatMap { walk($0, depth: depth + 1) }
        }
        return walk(rootFolder, depth: 0)
    }

    // MARK: Changes

    /// Copies picked/shared files into `folder` (the library root by default).
    @discardableResult
    func importFiles(_ urls: [URL], into folder: Folder? = nil) -> [Book] {
        let target = folder?.url ?? root
        var imported: [Book] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard DocumentOpener.canOpen(url) else { continue }
            if url.standardizedFileURL.path.hasPrefix(root.path + "/") {
                imported.append(Book(url: url))
                continue
            }
            let destination = LibraryFiles.uniqueURL(for: url.lastPathComponent, in: target)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                imported.append(Book(url: destination))
                // "Open with…" from another app lands a copy in Documents/Inbox; don't keep a duplicate.
                if url.deletingLastPathComponent().lastPathComponent == "Inbox" { try? FileManager.default.removeItem(at: url) }
            } catch {
                NSLog("Import failed for %@: %@", url.path, error.localizedDescription)
            }
        }
        reload()
        return imported
    }

    @discardableResult
    func createFolder(named name: String, in parent: Folder) throws -> Folder {
        let name = try Self.validName(name)
        let url = parent.url.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { reload() }
        mirrorInboxFolders()
        return Folder(url: url)
    }

    func rename(_ url: URL, to newName: String) throws {
        var name = try Self.validName(newName)
        // Books keep their extension even if the user types only a title.
        if !isDirectory(url) {
            let book = Book(url: url)
            let ext = book.format == "FB2" && url.pathExtension.lowercased() == "zip" ? "fb2.zip" : url.pathExtension
            if !name.lowercased().hasSuffix("." + ext.lowercased()) { name += "." + ext }
        }
        let target = url.deletingLastPathComponent().appending(path: name)
        guard target != url else { return }
        let wasFolder = isDirectory(url), oldPath = relativePath(url)
        try FileManager.default.moveItem(at: url, to: target)
        movePositions(from: url, to: target)
        if wasFolder { inbox?.mirrorMove(from: oldPath, to: relativePath(target)) }
        reload()
    }

    func move(_ url: URL, to folder: Folder) throws {
        guard folder.url != url, !folder.url.path.hasPrefix(url.path + "/") else { return }
        let target = LibraryFiles.uniqueURL(for: url.lastPathComponent, in: folder.url)
        let wasFolder = isDirectory(url), oldPath = relativePath(url)
        try FileManager.default.moveItem(at: url, to: target)
        movePositions(from: url, to: target)
        if wasFolder { inbox?.mirrorMove(from: oldPath, to: relativePath(target)) }
        reload()
    }

    /// Books inside a folder (all levels) — shown when confirming a folder deletion.
    func bookCount(in url: URL) -> Int {
        guard isDirectory(url) else { return 1 }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        return enumerator?.compactMap { $0 as? URL }.filter(DocumentOpener.canOpen).count ?? 0
    }

    func delete(_ url: URL) {
        if isDirectory(url) { inbox?.mirrorDelete(relativePath(url)) }
        try? FileManager.default.removeItem(at: url)
        let prefix = relativePath(url)
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where ["page:", "progress:", "positionDate:"].contains(where: { key.hasPrefix($0 + prefix) }) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        reload()
    }

    func open(_ book: Book) { path.append(.book(book)) }

    /// Highlight to scroll to once the book opened by a deep link has loaded.
    var pendingHighlight: UUID?
    /// Shown when a deep link names a book that isn't on this device.
    var missingBookMessage: String?

    /// Opens a `scriptorium://open?…` link.
    func open(_ link: DeepLink) async {
        guard let book = await locate(documentID: link.documentID, pathHint: nil) else {
            missingBookMessage = "That book isn't in the library on this device. Import it (or sync the Inbox) and try again."
            return
        }
        pendingHighlight = link.highlightID
        open(book, page: link.page, progress: link.progress)
    }

    /// Opens a book at a given place (from the all-bookmarks view).
    func open(_ book: Book, page: Int, progress: Double) {
        setLastPage(page, for: book)
        setLastProgress(progress, for: book)
        path = [.book(book)]
    }

    // MARK: Search and lookup

    /// Every book in the library, all folders.
    func allBooks() -> [Book] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter(DocumentOpener.canOpen).map(Book.init(url:))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func search(_ query: String) -> [Book] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return allBooks().filter { book in
            let name = relativePath(book.url)
            return terms.allSatisfy { name.localizedStandardContains($0) }
        }
    }

    /// Finds a book by content fingerprint (survives renames/moves); the stored path is tried first.
    func locate(documentID: String, pathHint: String?) async -> Book? {
        var candidates = allBooks()
        if let pathHint, let hinted = candidates.firstIndex(where: { relativePath($0.url) == pathHint }) {
            candidates.insert(candidates.remove(at: hinted), at: 0)
        }
        var cache = UserDefaults.standard.dictionary(forKey: "fingerprints") as? [String: String] ?? [:]
        defer { UserDefaults.standard.set(cache, forKey: "fingerprints") }
        for book in candidates {
            let values = try? book.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let key = "\(relativePath(book.url))|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            let id: String?
            if let cached = cache[key] {
                id = cached
            } else {
                let url = book.url
                id = await Task.detached(priority: .userInitiated) { try? DocumentFingerprint.id(for: url) }.value
                cache[key] = id
            }
            if id == documentID { return book }
        }
        return nil
    }

    // MARK: Reading position

    func lastPage(_ book: Book) -> Int {
        UserDefaults.standard.integer(forKey: "page:\(relativePath(book.url))")
    }

    func setLastPage(_ page: Int, for book: Book) {
        UserDefaults.standard.set(page, forKey: "page:\(relativePath(book.url))")
        UserDefaults.standard.set(Date(), forKey: "positionDate:\(relativePath(book.url))")
    }

    /// When this device last moved in the book (to compare with positions synced from other devices).
    func lastPositionDate(_ book: Book) -> Date? {
        UserDefaults.standard.object(forKey: "positionDate:\(relativePath(book.url))") as? Date
    }

    /// Position inside the page/chapter (0…1), for reflowable books.
    func lastProgress(_ book: Book) -> Double {
        UserDefaults.standard.double(forKey: "progress:\(relativePath(book.url))")
    }

    func setLastProgress(_ progress: Double, for book: Book) {
        UserDefaults.standard.set(progress, forKey: "progress:\(relativePath(book.url))")
        UserDefaults.standard.set(Date(), forKey: "positionDate:\(relativePath(book.url))")
    }

    // MARK: Helpers

    func relativePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : url.lastPathComponent
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Positions are keyed by relative path, so carry them over (for a folder: everything inside it).
    private func movePositions(from old: URL, to new: URL) {
        let oldPath = relativePath(old), newPath = relativePath(new)
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation() {
            for kind in ["page:", "progress:", "positionDate:"] {
                guard key == kind + oldPath || key.hasPrefix(kind + oldPath + "/") else { continue }
                defaults.set(value, forKey: kind + newPath + key.dropFirst((kind + oldPath).count))
                defaults.removeObject(forKey: key)
            }
        }
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return trimmed
    }
}
