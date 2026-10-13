import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

/// The library window: folders in the sidebar, the selected folder's books in a table.
struct MacLibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(MacRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(DeviceTransfers.self) private var transfers

    @State private var folderURL: URL?
    @State private var selection = Set<URL>()
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\BookRow.title)]
    @State private var showImporter = false
    @State private var newFolderName: String?
    @State private var renaming: URL?
    @State private var renameText = ""
    @State private var deleting: [URL] = []
    @State private var dropTargeted = false
    @State private var showNotes = false
    @State private var showReadLater = false

    private var folder: Folder { folderURL.map(Folder.init(url:)) ?? library.rootFolder }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } detail: {
            table
        }
        .navigationTitle(query.isEmpty ? (folderURL == nil ? "Library" : folder.name) : "Search")
        .searchable(text: $query, placement: .toolbar, prompt: "Search all books")
        .toolbar {
            ToolbarItemGroup {
                Button("Import Books", systemImage: "plus") { showImporter = true }
                    .help("Import books into this folder (or drop files on the window)")
                Button("New Folder", systemImage: "folder.badge.plus") { newFolderName = "" }
                Button("Bookmarks & Notes", systemImage: "bookmark") { showNotes = true }
                    .help("Bookmarks, highlights and notes from every book")
                Button("Read Later", systemImage: "text.badge.plus") { showReadLater = true }
                    .help("Links saved for later, from all your devices")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.bookTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            importFiles(urls)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL { urls.append(url) }
                    else if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                            let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                importFiles(urls)
            }
            return true
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if !transfers.received.isEmpty {
                    HStack {
                        Label("Received \(transfers.received.count) book\(transfers.received.count == 1 ? "" : "s") from your other devices: "
                              + transfers.received.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
                              systemImage: "paperplane")
                        Button("Dismiss", systemImage: "xmark") { transfers.received = [] }.labelStyle(.iconOnly).buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8).glassEffect(in: .capsule)
                }
                if let status = transfers.status {
                    Text(status).padding(.horizontal, 14).padding(.vertical, 8).glassEffect(in: .capsule)
                        .task(id: status) { if (try? await Task.sleep(for: .seconds(5))) != nil { transfers.status = nil } }
                }
            }
            .padding(.bottom, 16)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 3).padding(6).allowsHitTesting(false)
            }
        }
        .alert("New Folder", isPresented: Binding(get: { newFolderName != nil }, set: { if !$0 { newFolderName = nil } })) {
            TextField("Name", text: Binding(get: { newFolderName ?? "" }, set: { newFolderName = $0 }))
            Button("Create") {
                if let name = newFolderName, let created = try? library.createFolder(named: name, in: folder) {
                    folderURL = created.url
                }
                newFolderName = nil
            }
            Button("Cancel", role: .cancel) { newFolderName = nil }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let url = renaming { try? library.rename(url, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Move to Trash", role: .destructive) {
                for url in deleting { library.delete(url) }
                selection = []
                deleting = []
            }
        } message: {
            Text("Highlights, bookmarks and notes stay in iCloud and come back if you import the book again.")
        }
        .sheet(isPresented: $showNotes) {
            MacAllNotesView { book, page, progress in
                showNotes = false
                open(book, page: page, progress: progress)
            }
            .frame(minWidth: 560, minHeight: 520)
        }
        .sheet(isPresented: $showReadLater) { MacReadLaterView().frame(minWidth: 520, minHeight: 460) }
        .onChange(of: router.importRequested) { _, requested in
            if requested { showImporter = true; router.importRequested = false }
        }
        .onChange(of: router.newFolderRequested) { _, requested in
            if requested { newFolderName = ""; router.newFolderRequested = false }
        }
        .onChange(of: router.incoming) { _, urls in
            guard !urls.isEmpty else { return }
            router.incoming = []
            handleIncoming(urls)
        }
        .onAppear {
            if !router.incoming.isEmpty { handleIncoming(router.incoming); router.incoming = [] }
            DebugSnapshots.scheduleIfRequested()
            // Development: `-openBook "Physics/Thermodynamics.pdf"` opens a book window at launch.
            if let path = UserDefaults.standard.string(forKey: "openBook") {
                open(Book(url: library.root.appending(path: path)))
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let _ = library.revision
        return List(selection: $folderURL) {
            Section("Library") {
                Label("All Books", systemImage: "books.vertical").tag(nil as URL?)
                ForEach(library.allFolders().filter { $0.folder.url != library.root }, id: \.folder.url) { item in
                    Label(item.folder.name, systemImage: "folder")
                        .padding(.leading, CGFloat(max(0, item.depth - 1)) * 14)
                        .tag(Optional(item.folder.url))
                        .dropDestination(for: URL.self) { urls, _ in
                            moveOrImport(urls, into: item.folder)
                            return true
                        }
                        .contextMenu {
                            Button("Rename…") { renameText = item.folder.name; renaming = item.folder.url }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder.url]) }
                            Divider()
                            Button("Delete Folder…", role: .destructive) { deleting = [item.folder.url] }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Books

    struct BookRow: Identifiable {
        let book: Book
        let folder: String
        let size: Int64
        let modified: Date
        var id: URL { book.url }
        var title: String { book.title }
        var format: String { book.format }
    }

    private var rows: [BookRow] {
        let _ = library.revision
        let books: [Book]
        if !query.isEmpty {
            books = library.search(query)
        } else if folderURL == nil {
            books = library.allBooks()
        } else {
            books = library.contents(of: folder).books
        }
        return books.map { book in
            let values = try? book.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let parent = book.url.deletingLastPathComponent().standardizedFileURL
            return BookRow(book: book, folder: parent == library.root ? "" : parent.lastPathComponent,
                           size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate ?? .distantPast)
        }.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 8) {
                    MacThumbnail(url: row.book.url).frame(width: 22, height: 28)
                    Text(row.title).lineLimit(1)
                }
            }
            .width(min: 240, ideal: 420)
            TableColumn("Format", value: \.format).width(60)
            TableColumn("Folder", value: \.folder).width(min: 80, ideal: 140)
            TableColumn("Size", value: \.size) { row in
                Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file)).monospacedDigit()
            }
            .width(80)
            TableColumn("Modified", value: \.modified) { row in
                Text(row.modified, format: .dateTime.day().month().year())
            }
            .width(100)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if !urls.isEmpty {
                Button("Open") { urls.forEach { open(Book(url: $0)) } }
                if urls.count == 1, let url = urls.first {
                    SendToMenu(book: url)
                    SendToKindleButton(book: url)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
                if urls.count == 1, let url = urls.first {
                    Button("Rename…") { renameText = url.deletingPathExtension().lastPathComponent; renaming = url }
                }
                Menu("Move to") {
                    Button("Library") { moveOrImport(Array(urls), into: library.rootFolder) }
                    ForEach(library.allFolders().filter { $0.folder.url != library.root }, id: \.folder.url) { item in
                        Button(String(repeating: "   ", count: max(0, item.depth - 1)) + item.folder.name) { moveOrImport(Array(urls), into: item.folder) }
                    }
                }
                Divider()
                Button("Move to Trash…", role: .destructive) { deleting = Array(urls) }
            }
        } primaryAction: { urls in
            urls.forEach { open(Book(url: $0)) }
        }
        .onDeleteCommand { if !selection.isEmpty { deleting = Array(selection) } }
        .overlay {
            if rows.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView("No Books", systemImage: "books.vertical",
                                           description: Text("Drop PDF, DjVu, EPUB, FB2, AZW3, Word, CHM or web archive files here, or use Import."))
                }
            }
        }
    }

    // MARK: Actions

    static let bookTypes: [UTType] = [.pdf, .epub, .webArchive, .data]

    private var deleteTitle: String {
        deleting.count == 1 ? "Move “\(deleting[0].deletingPathExtension().lastPathComponent)” to the Trash?" : "Move \(deleting.count) items to the Trash?"
    }

    private func importFiles(_ urls: [URL]) {
        let books = urls.flatMap { url -> [Book] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return library.importFiles([url], into: folderURL == nil ? nil : folder)
        }
        selection = Set(books.map(\.url))
    }

    private func moveOrImport(_ urls: [URL], into target: Folder) {
        for url in urls {
            if url.standardizedFileURL.path.hasPrefix(library.root.path + "/") {
                try? library.move(url, to: target)
            } else {
                let scoped = url.startAccessingSecurityScopedResource()
                _ = library.importFiles([url], into: target)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    /// Files opened from Finder are imported (the library is a copy, like on the iPad); scriptorium://
    /// links open the book at the linked place.
    private func handleIncoming(_ urls: [URL]) {
        for url in urls {
            if let link = DeepLink(url: url) {
                Task {
                    guard let book = await library.locate(documentID: link.documentID, pathHint: nil) else { return }
                    library.pendingHighlight = link.highlightID
                    open(book, page: link.page, progress: link.progress)
                }
            } else if url.isFileURL {
                let scoped = url.startAccessingSecurityScopedResource()
                let books = library.importFiles([url])
                if scoped { url.stopAccessingSecurityScopedResource() }
                books.forEach { open($0) }
            }
        }
    }

    private func open(_ book: Book, page: Int? = nil, progress: Double = 0) {
        if let page {
            library.setLastPage(page, for: book)
            library.setLastProgress(progress, for: book)
        }
        openWindow(id: "book", value: book.url)
    }
}

/// First-page thumbnail, rendered once and cached.
struct MacThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            } else {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
            }
        }
        .task(id: url) { image = await MacThumbnailCache.shared.image(for: url) }
    }
}

actor MacThumbnailCache {
    static let shared = MacThumbnailCache()
    private var cache: [URL: NSImage] = [:]

    func image(for url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }
        let cg: CGImage? = await Task.detached(priority: .utility) {
            guard let source = try? DocumentOpener.open(url), source.pageCount > 0 else { return nil }
            return try? source.renderPage(at: 0, maxPixelSize: 120)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[url] = image
        return image
    }
}
