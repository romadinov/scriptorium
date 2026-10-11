import ReaderCore
import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var library = library
        NavigationStack(path: $library.path) {
            FolderView(folder: library.rootFolder)
                .alert("Book not found", isPresented: Binding(get: { library.missingBookMessage != nil },
                                                             set: { if !$0 { library.missingBookMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(library.missingBookMessage ?? "")
                }
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .folder(let folder): FolderView(folder: folder)
                    case .book(let book): ReaderScreen(book: book)
                    }
                }
        }
    }
}

private struct FolderView: View {
    let folder: Folder
    @Environment(LibraryStore.self) private var library
    @State private var folders: [Folder] = []
    @State private var books: [Book] = []
    @State private var importing = false
    @State private var showSettings = false
    @State private var showTransfer = false
    @State private var naming: NamingTask?
    @State private var moving: URL?
    @State private var deleting: URL?
    @State private var errorMessage: String?
    @State private var inboxReport: InboxSync.Report?
    @State private var showReadLater = false
    @State private var showNotes = false
    @State private var query = ""
    @AppStorage("libraryLayout") private var layout: LibraryLayout = .list

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 24)]
    private var isRoot: Bool { folder.url == library.root }

    var body: some View {
        ScrollView {
            if !query.isEmpty {
                SearchResults(results: library.search(query))
            } else if folders.isEmpty && books.isEmpty {
                ContentUnavailableView {
                    Label(isRoot ? "No books yet" : "Empty folder", systemImage: isRoot ? "books.vertical" : "folder")
                } description: {
                    Text("Import PDF, DjVu, EPUB or FB2 files, or upload them from a computer with Wi-Fi Transfer.")
                } actions: {
                    Button("Import…") { importing = true }.buttonStyle(.borderedProminent)
                    Button("Wi-Fi Transfer") { showTransfer = true }
                }
                .padding(.top, 120)
            } else if layout == .list {
                LazyVStack(spacing: 0) {
                    ForEach(folders) { sub in
                        NavigationLink(value: LibraryRoute.folder(sub)) { FolderRow(folder: sub) }
                            .buttonStyle(.plain)
                            .contextMenu { itemMenu(sub.url, name: sub.name) }
                        Divider().padding(.leading, 84)
                    }
                    ForEach(books) { book in
                        NavigationLink(value: LibraryRoute.book(book)) { BookRow(book: book) }
                            .buttonStyle(.plain)
                            .contextMenu { itemMenu(book.url, name: book.title) }
                        Divider().padding(.leading, 84)
                    }
                }
                .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(folders) { sub in
                        NavigationLink(value: LibraryRoute.folder(sub)) { FolderCell(folder: sub) }
                            .buttonStyle(.plain)
                            .contextMenu { itemMenu(sub.url, name: sub.name) }
                    }
                    ForEach(books) { book in
                        NavigationLink(value: LibraryRoute.book(book)) { BookCell(book: book) }
                            .buttonStyle(.plain)
                            .contextMenu { itemMenu(book.url, name: book.title) }
                    }
                }
                .padding(24)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !library.autoImported.isEmpty {
                ImportBanner(paths: library.autoImported) { library.autoImported = [] }
                    .padding()
            }
        }
        .searchable(text: $query, prompt: "Search all books")
        .navigationTitle(isRoot ? "Library" : folder.name)
        .refreshable { await syncInbox() }
        .task(id: library.revision) { reload() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if isRoot {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                Button(layout == .list ? "Show as grid" : "Show as list",
                       systemImage: layout == .list ? "square.grid.2x2" : "list.bullet") {
                    layout = layout == .list ? .grid : .list
                }
                Button("Read Later", systemImage: "text.badge.plus") { showReadLater = true }
                Button("Bookmarks", systemImage: "bookmark") { showNotes = true }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if library.isSyncingInbox {
                    ProgressView()
                } else {
                    Button("Sync iCloud Inbox", systemImage: "icloud.and.arrow.down") { Task { await syncInbox() } }
                }
                Button("Wi-Fi Transfer", systemImage: "wifi") { showTransfer = true }
                Button("New Folder", systemImage: "folder.badge.plus") { naming = .newFolder }
                Button("Import", systemImage: "plus") { importing = true }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .djvu, .epub, .fb2, .zip, .webArchive, .chm],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls, into: folder) }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showTransfer) { TransferView() }
        .sheet(isPresented: $showReadLater) { ReadLaterView() }
        .sheet(isPresented: $showNotes) { AllNotesView() }
        .sheet(item: $moving) { url in
            MovePicker(item: url) { destination in
                perform { try library.move(url, to: destination) }
                moving = nil
            }
        }
        .alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }),
               presenting: naming) { task in
            NameField(initial: task.initialName) { name in
                perform {
                    switch task {
                    case .newFolder: try library.createFolder(named: name, in: folder)
                    case .rename(let url, _): try library.rename(url, to: name)
                    }
                }
            }
        }
        .confirmationDialog("Delete?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { url in
            Button("Delete \(url.lastPathComponent)", role: .destructive) { library.delete(url) }
        } message: { url in
            Text(library.isDirectory(url) ? "The folder and every book in it will be deleted." : "This book will be deleted from the iPad.")
        }
        .alert("Inbox synced", isPresented: Binding(get: { inboxReport != nil }, set: { if !$0 { inboxReport = nil } }),
               presenting: inboxReport) { _ in
            Button("OK", role: .cancel) {}
        } message: { report in
            Text(inboxMessage(report))
        }
        .alert("Couldn't complete that", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func itemMenu(_ url: URL, name: String) -> some View {
        Button("Rename", systemImage: "pencil") { naming = .rename(url, name) }
        Button("Move to…", systemImage: "folder") { moving = url }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = url }
    }

    private func syncInbox() async {
        if let report = await library.syncInbox() { inboxReport = report }
    }

    private func inboxMessage(_ report: InboxSync.Report) -> String {
        var lines = [report.summary]
        if !report.imported.isEmpty { lines.append(report.imported.prefix(8).joined(separator: "\n")) }
        if !report.failed.isEmpty {
            lines.append("Failed:\n" + report.failed.prefix(5).map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        }
        if report.imported.isEmpty && report.failed.isEmpty {
            lines.append("Drop books into \(library.inboxLocation) — into any subfolder — then sync.")
        }
        return lines.joined(separator: "\n\n")
    }

    private func reload() {
        (folders, books) = library.contents(of: folder)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

/// Books whose name or folder matches the search, from every folder.
private struct SearchResults: View {
    let results: [Book]
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView.search
        } else {
            LazyVStack(spacing: 0) {
                ForEach(results) { book in
                    NavigationLink(value: LibraryRoute.book(book)) {
                        VStack(alignment: .leading, spacing: 0) {
                            BookRow(book: book)
                            let folder = (library.relativePath(book.url) as NSString).deletingLastPathComponent
                            if !folder.isEmpty {
                                Label(folder, systemImage: "folder").font(.caption2).foregroundStyle(.secondary)
                                    .padding(.leading, 84).padding(.bottom, 8).offset(y: -6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 84)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// Bookmarks (or highlights) from every book, searchable; tapping opens the book at that place.
private struct AllNotesView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var books: [BookHighlights] = []
    @State private var tab = 0
    @State private var query = ""
    @State private var notFound: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $tab) {
                    Text("Bookmarks").tag(0)
                    Text("Highlights").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                ForEach(filtered, id: \.documentID) { book in
                    Section(book.title) {
                        if tab == 0 {
                            ForEach(book.bookmarks.filter(matches)) { mark in
                                row(icon: "bookmark.fill", title: mark.label, detail: mark.snippet) {
                                    open(book, page: mark.page, progress: mark.progress)
                                }
                            }
                        } else {
                            ForEach(book.highlights.filter(matches)) { h in
                                row(icon: "highlighter", title: h.text, detail: nil, tint: h.color.swiftUI) {
                                    open(book, page: h.location.pageIndex, progress: 0)
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if loading {
                    ProgressView()
                } else if filtered.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView(tab == 0 ? "No bookmarks" : "No highlights",
                                               systemImage: tab == 0 ? "bookmark" : "highlighter")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search bookmarks and books")
            .navigationTitle(tab == 0 ? "All Bookmarks" : "All Highlights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Book not in this library", isPresented: Binding(get: { notFound != nil }, set: { if !$0 { notFound = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("“\(notFound ?? "")” isn't on this device. Import it (or sync the Inbox) to open it here.")
            }
        }
        .task {
            books = await HighlightStore.shared.allBooks().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            loading = false
        }
    }

    private var filtered: [BookHighlights] {
        books.filter { book in
            let items = tab == 0 ? book.bookmarks.count : book.highlights.count
            guard items > 0 else { return false }
            return query.isEmpty || book.title.localizedStandardContains(query)
                || (tab == 0 ? book.bookmarks.contains(where: matches) : book.highlights.contains(where: matches))
        }
    }

    private func matches(_ mark: Bookmark) -> Bool {
        query.isEmpty || mark.snippet.localizedStandardContains(query) || mark.label.localizedStandardContains(query)
            || books.contains { $0.bookmarks.contains(mark) && $0.title.localizedStandardContains(query) }
    }

    private func matches(_ h: Highlight) -> Bool {
        query.isEmpty || h.text.localizedStandardContains(query) || (h.note ?? "").localizedStandardContains(query)
            || books.contains { $0.highlights.contains(h) && $0.title.localizedStandardContains(query) }
    }

    private func row(icon: String, title: String, detail: String?, tint: Color = .accentColor,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).lineLimit(3).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
    }

    private func open(_ book: BookHighlights, page: Int, progress: Double) {
        Task {
            guard let local = await library.locate(documentID: book.documentID, pathHint: book.path) else {
                notFound = book.title
                return
            }
            dismiss()
            library.open(local, page: page, progress: progress)
        }
    }
}

enum LibraryLayout: String {
    case list, grid
}

private struct BookRow: View {
    let book: Book
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(radius: 1, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        .overlay { Image(systemName: "doc.text").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 44, height: 60)
            .padding(.leading, 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.body).lineLimit(2)
                Text(book.format).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.trailing, 24)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .task(id: book.url) { thumbnail = await Thumbnails.shared.image(for: book.url) }
    }
}

private struct FolderRow: View {
    let folder: Folder
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "folder.fill").font(.title).foregroundStyle(.tint)
                .frame(width: 44, height: 60).padding(.leading, 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name).font(.body.weight(.medium))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.trailing, 24)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var summary: String {
        _ = library.revision
        let (folders, books) = library.contents(of: folder)
        return [folders.isEmpty ? nil : "\(folders.count) folder\(folders.count == 1 ? "" : "s")",
                "\(books.count) book\(books.count == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The Read Later list (iCloud Drive › Scriptorium › Read Later.md), newest last as in the file.
private struct ReadLaterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var entries: [ReadLaterList.Entry] = []
    @State private var location = ""

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("Nothing to read later", systemImage: "text.badge.plus",
                                           description: Text("Long-press a link in a book and choose Add to Read Later."))
                } else {
                    List(entries.indices, id: \.self) { i in
                        let entry = entries[i]
                        Button {
                            if let url = URL(string: entry.url) { openURL(url) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).strikethrough(entry.done).foregroundStyle(entry.done ? .secondary : .primary)
                                Text(entry.url).font(.caption).foregroundStyle(.tint).lineLimit(1)
                                if let source = entry.source { Text("From \(source)").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Read Later")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if !location.isEmpty {
                    Text("Saved as text in \(location). Mark items @done in TaskPaper or any text editor.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
        }
        .task {
            let (list, isCloud) = await Task.detached {
                (ReadLaterList(file: InboxLocation.readLaterFile()),
                 ICloudFiles.documentsDirectory(containerIdentifier: InboxLocation.containerIdentifier) != nil)
            }.value
            entries = await Task.detached { list.entries() }.value
            location = isCloud ? "iCloud Drive › Scriptorium › Read Later.md" : "On My iPad › Scriptorium › Read Later.md"
        }
    }
}

private struct ImportBanner: View {
    let paths: [String]
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "icloud.and.arrow.down").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Imported \(paths.count) book\(paths.count == 1 ? "" : "s") from your iCloud Inbox").font(.headline)
                Text(paths.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                     + (paths.count > 3 ? " and \(paths.count - 3) more" : ""))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: onDismiss).labelStyle(.iconOnly).buttonStyle(.plain)
        }
        .padding(14)
        .glassEffect(in: .rect(cornerRadius: 16))
        .task(id: paths.count) {
            try? await Task.sleep(for: .seconds(8))
            onDismiss()
        }
    }
}

private enum NamingTask: Identifiable {
    case newFolder
    case rename(URL, String)

    var id: String {
        switch self {
        case .newFolder: "new"
        case .rename(let url, _): url.path
        }
    }

    var title: String {
        switch self {
        case .newFolder: "New Folder"
        case .rename: "Rename"
        }
    }

    var initialName: String {
        switch self {
        case .newFolder: ""
        case .rename(_, let name): name
        }
    }
}

/// Text field + buttons for an alert; owns its own text state.
private struct NameField: View {
    let initial: String
    let onSave: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("Name", text: $text)
            .onAppear { text = initial }
        Button("Cancel", role: .cancel) {}
        Button("Save") { onSave(text) }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private struct MovePicker: View {
    let item: URL
    let onPick: (Folder) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(library.allFolders(), id: \.folder.id) { entry in
                let invalid = entry.folder.url == item || entry.folder.url.path.hasPrefix(item.path + "/")
                    || entry.folder.url == item.deletingLastPathComponent().standardizedFileURL
                Button {
                    onPick(entry.folder)
                } label: {
                    Label(entry.depth == 0 ? "Library" : entry.folder.name,
                          systemImage: entry.depth == 0 ? "books.vertical" : "folder")
                        .padding(.leading, CGFloat(entry.depth) * 20)
                }
                .disabled(invalid)
            }
            .navigationTitle("Move “\(Book(url: item).title)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct FolderCell: View {
    let folder: Folder
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6))
                Image(systemName: "folder.fill").font(.system(size: 56)).foregroundStyle(.tint)
            }
            .aspectRatio(0.72, contentMode: .fit)
            Text(folder.name).font(.subheadline).lineLimit(2)
            Text(summary).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        _ = library.revision   // re-count when files change (e.g. a Wi-Fi upload into this folder)
        let (folders, books) = library.contents(of: folder)
        return [folders.isEmpty ? nil : "\(folders.count) folder\(folders.count == 1 ? "" : "s")",
                "\(books.count) book\(books.count == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct BookCell: View {
    let book: Book
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(radius: 3, y: 2)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        VStack(spacing: 8) {
                            Image(systemName: icon).font(.largeTitle)
                            Text(book.title).font(.caption).multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 8)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .aspectRatio(0.72, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .bottom)

            Text(book.title).font(.subheadline).lineLimit(2)
            Text(book.format).font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: book.url) { thumbnail = await Thumbnails.shared.image(for: book.url) }
    }

    private var icon: String {
        switch book.format {
        case "EPUB", "FB2": "book.closed"
        case "DJVU", "DJV": "doc.richtext"
        default: "doc.text"
        }
    }
}

actor Thumbnails {
    static let shared = Thumbnails()
    private var cache: [URL: UIImage] = [:]

    func image(for url: URL) async -> UIImage? {
        if let cached = cache[url] { return cached }
        let image: UIImage? = await Task.detached(priority: .utility) {
            guard let source = try? DocumentOpener.open(url), source.pageCount > 0,
                  let cg = try? source.renderPage(at: 0, maxPixelSize: 480) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        cache[url] = image
        return image
    }
}
