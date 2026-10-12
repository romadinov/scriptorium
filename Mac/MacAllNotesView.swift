import ReaderCore
import SwiftUI

/// Bookmarks, highlights and notes from every book (synced from all devices), searchable.
struct MacAllNotesView: View {
    let onOpen: (Book, Int, Double) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var books: [BookHighlights] = []
    @State private var query = ""
    @State private var tab = 0
    @State private var notFound: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.documentID) { book in
                    Section(book.title) {
                        if tab == 0 {
                            ForEach(book.bookmarks.filter(matches)) { mark in
                                row(icon: mark.hasAnnotation ? "note.text" : "bookmark.fill", title: mark.label,
                                    detail: mark.snippet, annotation: mark) { open(book, page: mark.page, progress: mark.progress) }
                            }
                        } else {
                            ForEach(book.highlights.filter(matches)) { h in
                                row(icon: "highlighter", title: h.text, detail: nil, annotation: h, tint: h.color.swiftUI) {
                                    library.pendingHighlight = h.id
                                    open(book, page: h.location.pageIndex, progress: 0)
                                }
                            }
                        }
                    }
                }
            }
            .overlay { if filtered.isEmpty { ContentUnavailableView(tab == 0 ? "No Bookmarks" : "No Highlights", systemImage: "bookmark") } }
            .searchable(text: $query, prompt: "Search bookmarks, highlights, notes and books")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $tab) {
                        Text("Bookmarks & Page Notes").tag(0)
                        Text("Highlights & Notes").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Book not in this library", isPresented: Binding(get: { notFound != nil }, set: { if !$0 { notFound = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("“\(notFound ?? "")” isn't on this Mac. Import it to open it here.")
            }
        }
        .task {
            books = await HighlightStore.shared.allBooks().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    private var filtered: [BookHighlights] {
        books.filter { book in
            let count = tab == 0 ? book.bookmarks.filter(matches).count : book.highlights.filter(matches).count
            return count > 0 || (!query.isEmpty && book.title.localizedStandardContains(query) && (tab == 0 ? !book.bookmarks.isEmpty : !book.highlights.isEmpty))
        }
    }

    private func matches(_ mark: Bookmark) -> Bool {
        query.isEmpty || mark.snippet.localizedStandardContains(query) || (mark.note ?? "").localizedStandardContains(query)
            || books.contains { $0.bookmarks.contains(mark) && $0.title.localizedStandardContains(query) }
    }

    private func matches(_ h: Highlight) -> Bool {
        query.isEmpty || h.text.localizedStandardContains(query) || (h.note ?? "").localizedStandardContains(query)
            || books.contains { $0.highlights.contains(h) && $0.title.localizedStandardContains(query) }
    }

    private func row(icon: String, title: String, detail: String?, annotation: any Annotatable, tint: Color = .accentColor,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).lineLimit(3)
                    if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                    MacAnnotationSummary(item: annotation)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func open(_ book: BookHighlights, page: Int, progress: Double) {
        Task {
            guard let local = await library.locate(documentID: book.documentID, pathHint: book.path) else {
                notFound = book.title
                return
            }
            onOpen(local, page, progress)
        }
    }
}
