import Foundation
import Testing
@testable import ReaderCore

@Suite struct InboxSyncTests {
    let library: URL
    let inbox: URL
    let sync: InboxSync

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        library = root.appending(path: "Books")
        inbox = root.appending(path: "Inbox")
        try FileManager.default.createDirectory(at: library.appending(path: "Physics/Thermo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.appending(path: "Fiction"), withIntermediateDirectories: true)
        sync = InboxSync(library: library, inbox: inbox, ensureDownloaded: { _ in })
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    @Test func mirrorsAllLibraryFolders() throws {
        #expect(try sync.mirrorFolders() == 3)
        #expect(exists("Physics/Thermo", in: inbox) && exists("Fiction", in: inbox))
        #expect(try sync.mirrorFolders() == 0)    // idempotent
    }

    @Test func recognisesBooksSavedWithoutAnExtension() async throws {
        try write("%PDF-1.7\nrest", "Articles/Thinking Inertia ", in: inbox)   // a share sheet dropped ".pdf"
        try write("just some notes", "Articles/README", in: inbox)
        let report = await sync.sync()
        #expect(report.imported == ["Articles/Thinking Inertia.pdf"])
        #expect(report.skipped == ["Articles/README"])
        #expect(exists("Articles/Thinking Inertia.pdf", in: library))
        #expect(!exists("Articles/Thinking Inertia ", in: inbox) && exists("Articles/README", in: inbox))
    }

    @Test func importsIntoMatchingFoldersAndEmptiesInbox() async throws {
        try sync.mirrorFolders()
        try write("pdf-1", "Physics/Thermo/Entropy.pdf", in: inbox)
        try write("epub-1", "Fiction/Austen/Pride.epub", in: inbox)         // folder made in the Inbox
        try write("fb2", "Root book.fb2.zip", in: inbox)
        try write("notes", "Fiction/readme.txt", in: inbox)                 // not a book
        try write("dup", "Fiction/Same.epub", in: library)
        try write("dup", "Fiction/Same.epub", in: inbox)                    // identical copy already imported
        try write("other", "Fiction/Clash.pdf", in: library)
        try write("new", "Fiction/Clash.pdf", in: inbox)                    // same name, different book

        let report = await sync.sync()

        #expect(Set(report.imported) == ["Physics/Thermo/Entropy.pdf", "Fiction/Austen/Pride.epub",
                                         "Root book.fb2.zip", "Fiction/Clash 2.pdf"])
        #expect(report.foldersCreated == ["Fiction/Austen"])
        #expect(report.duplicates == ["Fiction/Same.epub"])
        #expect(report.skipped == ["Fiction/readme.txt"])
        #expect(report.failed.isEmpty)
        #expect(try String(contentsOf: library.appending(path: "Fiction/Austen/Pride.epub"), encoding: .utf8) == "epub-1")
        // Books are gone from the Inbox; folders (incl. the new one) and the unsupported file remain.
        #expect(InboxSync.files(under: inbox).map(\.relative) == ["Fiction/readme.txt"])
        #expect(exists("Fiction/Austen", in: inbox) && exists("Physics/Thermo", in: inbox))
        #expect(report.summary == "4 books imported, 1 new folder, 1 already in the library, 1 unsupported file left in the Inbox.")
    }

    @Test func folderRenameAndDeleteMirrorOnlyWhenEmpty() throws {
        try sync.mirrorFolders()
        sync.mirrorMove(from: "Fiction", to: "Novels")
        #expect(!exists("Fiction", in: inbox) && exists("Novels", in: inbox))

        try write("waiting", "Physics/Thermo/Pending.pdf", in: inbox)
        sync.mirrorDelete("Physics")                                        // holds a pending book → kept
        #expect(exists("Physics/Thermo/Pending.pdf", in: inbox))
        sync.mirrorDelete("Novels")
        #expect(!exists("Novels", in: inbox))
    }

    @Test func placeholderNamesMapToRealNames() throws {
        try write("", "Fiction/.Pride.epub.icloud", in: inbox)
        try write("", ".DS_Store", in: inbox)
        #expect(InboxSync.files(under: inbox).map(\.relative) == ["Fiction/Pride.epub"])
    }
}
